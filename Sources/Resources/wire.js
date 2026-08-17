// UniReader 二进制线格式编解码器（浏览器采集页 + node 测试共用单一真源）。
// 契约见 PROTOCOL.md。改这里必须同步 Sources/Server/WireCodec.swift。
// 全部小端。一个 WS 二进制帧 = [u8 opcode][payload]。
(function (root, factory) {
  var mod = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = mod; // node
  root.Wire = mod;                                                            // 浏览器 window.Wire
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var OP = {
    auth: 0x01, authOK: 0x02, authFail: 0x03,
    ping: 0x10, pong: 0x11, latency: 0x12,
    selectDoc: 0x20, pageTurn: 0x21, mode: 0x22, pen: 0x23, textNote: 0x24, penset: 0x25,
    layerSelect: 0x26, layerVisible: 0x27, layerAdd: 0x28, gotoPage: 0x29, openDoc: 0x2A,
    scratchOpen: 0x2B, scratchAdd: 0x2C, scratchPaper: 0x2D, scratchMove: 0x2E, scratchPageShow: 0x2F,
    page: 0x30, layout: 0x31, viewport: 0x32, docs: 0x33, pens: 0x34, inkCancel: 0x35, strokes: 0x36,
    radial: 0x37, pressRing: 0x38, notes: 0x39, layers: 0x3A, library: 0x3B, toc: 0x3C,
    scratchPads: 0x3D, scratchStrokes: 0x3E, noteNew: 0x3F,
    scroll: 0x40, hover: 0x41, ink: 0x42, erase: 0x43, probe: 0x44, padGeom: 0x45, eraser: 0x46,
    lassoMove: 0x47, scratchDelete: 0x48, scratchRename: 0x49, lassoScale: 0x4A,
    nack: 0x50
  };
  var BRUSH = ["ballpoint", "fountain", "marker", "pencil"];
  var MODEK = ["note", "erase", "page", "lasso"];
  // 环形盘扇区类型。**只许尾部追加**（kind≠0 的项 pen 字段是占位 0，照旧按定长读掉）。
  var RKIND = ["pen", "erase", "page", "scratchAdd", "textNote"];
  var NO_HL = 0xFFFF;                        // highlight 线上哨兵：无高亮（中心取消区）→ 对象里 -1
  var NO_PAD = 0xFFFF;
  // 草稿纸底纹：0=plain 1=dots 2=grid（同 BRUSH/MODEK 的编码惯例，越界回退 dots）
  var PATK = ["plain", "dots", "grid"];
  function patCode(p) { var i = PATK.indexOf(p); return i < 0 ? 1 : i; }                       // 草稿纸「一张都没开」的线上哨兵 → 对象里 -1
  var PH = { begin: 0, move: 1, end: 2 };
  var PHNAME = ["begin", "move", "end"];

  var te = new TextEncoder(), td = new TextDecoder();

  function brushCode(t) { var i = BRUSH.indexOf(t); return i < 0 ? 0 : i; }
  function modeCode(m) { var i = MODEK.indexOf(m); return i < 0 ? 0 : i; }
  function rkindCode(k) { var i = RKIND.indexOf(k); return i < 0 ? 0 : i; }

  // "rgba(24,90,210,0.95)" / "rgb(...)" -> [r,g,b,a]（r/g/b 0~255 整数，a 0~1）
  function parseColor(css) {
    var m = /rgba?\(([^)]+)\)/.exec(css || "");
    if (!m) return [0, 0, 0, 1];
    var p = m[1].split(",").map(function (s) { return parseFloat(s); });
    return [p[0] | 0, p[1] | 0, p[2] | 0, p.length > 3 ? p[3] : 1];
  }

  // ---- Writer（动态增长 Uint8Array）----
  function Writer() { this.buf = new Uint8Array(64); this.n = 0; }
  Writer.prototype._ensure = function (k) {
    if (this.n + k <= this.buf.length) return;
    var cap = this.buf.length; while (cap < this.n + k) cap *= 2;
    var nb = new Uint8Array(cap); nb.set(this.buf); this.buf = nb;
  };
  Writer.prototype.u8 = function (v) { this._ensure(1); this.buf[this.n++] = v & 255; };
  Writer.prototype.u16 = function (v) { this._ensure(2); this.buf[this.n++] = v & 255; this.buf[this.n++] = (v >>> 8) & 255; };
  Writer.prototype.u32 = function (v) {
    this._ensure(4);
    this.buf[this.n++] = v & 255; this.buf[this.n++] = (v >>> 8) & 255;
    this.buf[this.n++] = (v >>> 16) & 255; this.buf[this.n++] = (v >>> 24) & 255;
  };
  Writer.prototype.f32 = function (v) { this._ensure(4); new DataView(this.buf.buffer, this.n, 4).setFloat32(0, v, true); this.n += 4; };
  Writer.prototype.f64 = function (v) { this._ensure(8); new DataView(this.buf.buffer, this.n, 8).setFloat64(0, v, true); this.n += 8; };
  Writer.prototype.str = function (s) {
    var b = te.encode(s == null ? "" : "" + s);
    if (b.length > 65535) b = b.subarray(0, 65535);
    this.u16(b.length); this._ensure(b.length); this.buf.set(b, this.n); this.n += b.length;
  };
  Writer.prototype.pen = function (pen) {
    var c = parseColor(pen && pen.color);
    this.u8(c[0]); this.u8(c[1]); this.u8(c[2]); this.f32(c[3]);
    this.f32((pen && pen.w) || 0); this.u8(brushCode(pen && pen.t));
  };
  Writer.prototype.pts = function (arr, dim) {   // dim=2(pt2) / 3(pt3)
    arr = arr || []; this.u16(arr.length);
    for (var i = 0; i < arr.length; i++) {
      var p = arr[i];
      this.f32(p[0]); this.f32(p[1]);
      if (dim === 3) this.f32(p.length > 2 ? p[2] : 0.5);
    }
  };
  Writer.prototype.bytes = function () { return this.buf.subarray(0, this.n); };
  // 尾部可选多边形（lassoMove/lassoScale，PROTOCOL.md §4.1）：扁平数组 [x0,y0,x1,y1,…]，
  // 缺省/<3 点一律不写（老形态字节不变）。
  Writer.prototype.polyTail = function (poly) {
    if (!poly || poly.length < 6) return;
    this.u16(poly.length / 2);
    for (var i = 0; i < poly.length; i++) this.f32(poly[i]);
  };

  // ---- Reader ----
  function Reader(ab) {
    if (ab instanceof Uint8Array) { this.dv = new DataView(ab.buffer, ab.byteOffset, ab.byteLength); }
    else { this.dv = new DataView(ab); }
    this.n = 0; this.len = this.dv.byteLength;
  }
  Reader.prototype.u8 = function () { return this.dv.getUint8(this.n++); };
  Reader.prototype.u16 = function () { var v = this.dv.getUint16(this.n, true); this.n += 2; return v; };
  Reader.prototype.u32 = function () { var v = this.dv.getUint32(this.n, true); this.n += 4; return v; };
  Reader.prototype.f32 = function () { var v = this.dv.getFloat32(this.n, true); this.n += 4; return v; };
  Reader.prototype.f64 = function () { var v = this.dv.getFloat64(this.n, true); this.n += 8; return v; };
  Reader.prototype.str = function () {
    var L = this.u16(); var b = new Uint8Array(this.dv.buffer, this.dv.byteOffset + this.n, L); this.n += L; return td.decode(b);
  };
  Reader.prototype.left = function () { return this.len - this.n; };   // 尾部可选字段用（gotoPage.frac）
  // 尾部可选多边形（lassoMove/lassoScale）：无尾部 → null（矩形命中）；截断/残缺 → null。
  Reader.prototype.polyTail = function () {
    if (this.left() < 2) return null;
    var m = this.u16();
    if (m < 3 || this.left() < m * 8) return null;
    var out = new Array(m * 2);
    for (var i = 0; i < m * 2; i++) out[i] = this.f32();
    return out;
  };
  Reader.prototype.pen = function () {
    var r = this.u8(), g = this.u8(), b = this.u8(), a = this.f32(), w = this.f32(), t = this.u8();
    return { color: "rgba(" + r + "," + g + "," + b + "," + a + ")", w: w, t: BRUSH[t] || "ballpoint" };
  };
  Reader.prototype.pts = function (dim) {
    var m = this.u16(), out = new Array(m);
    for (var i = 0; i < m; i++) out[i] = dim === 3 ? [this.f32(), this.f32(), this.f32()] : [this.f32(), this.f32()];
    return out;
  };

  // ---- encode(object) -> Uint8Array ----
  function encode(o) {
    var w = new Writer();
    switch (o.type) {
      case "auth": w.u8(OP.auth); w.str(o.token); break;
      case "authOK": w.u8(OP.authOK); w.u32(o.session || 0); w.u16(o.udpPort || 0); break;
      case "authFail": w.u8(OP.authFail); break;
      case "ping": w.u8(OP.ping); w.f64(o.t || 0); break;
      case "pong": w.u8(OP.pong); w.f64(o.t || 0); break;
      case "latency": w.u8(OP.latency); w.f32(o.ms || 0); break;
      case "selectDoc": w.u8(OP.selectDoc); w.str(o.id || ""); break;
      case "pageTurn": w.u8(OP.pageTurn); w.u8(o.dir === "prev" ? 0 : 1); break;
      // frac 是尾部可选 f32（PROTOCOL.md §4.1）：0/缺省一律省略，「只跳页」的老形态字节不变。
      case "gotoPage": w.u8(OP.gotoPage); w.u32(o.page || 0); if (o.frac) w.f32(o.frac); break;
      case "openDoc": w.u8(OP.openDoc); w.str(o.id || ""); break;
      case "mode": w.u8(OP.mode); w.u8(modeCode(o.mode)); break;
      case "pen": w.u8(OP.pen); w.u16(o.index || 0); break;
      case "penset": {
        // 平板改笔宽后上行（C→S）：payload 布局与 `pens` 完全相同。
        w.u8(OP.penset); w.u16(o.active || 0);
        var PS = o.list || []; w.u16(PS.length);
        for (var pk = 0; pk < PS.length; pk++) w.pen(PS[pk]);
        break;
      }
      case "eraser":
        w.u8(OP.eraser); w.f32(o.size || 0);
        w.u8(o.mode == null ? 1 : o.mode);              // 0=整笔 1=局部（默认局部）
        w.u8(o.ring == null ? 1 : (o.ring ? 1 : 0));    // 尺寸圆环（默认开）
        break;
      case "textNote":
        w.u8(OP.textNote); w.str(o.id || ""); w.u8(o.op === "delete" ? 1 : 0);
        w.u32(o.page || 0); w.f32(o.nx || 0); w.f32(o.ny || 0); w.str(o.text || ""); break;
      case "notes": {
        w.u8(OP.notes); var NL = o.list || []; w.u16(NL.length);
        for (var ni = 0; ni < NL.length; ni++) {
          w.str(NL[ni].id || ""); w.u32(NL[ni].page || 0);
          w.f32(NL[ni].nx || 0); w.f32(NL[ni].ny || 0); w.str(NL[ni].text || "");
        }
        break;
      }
      case "page":
        w.u8(OP.page); w.u32(o.v || 0); w.u32(o.index || 0); w.u32(o.count || 0); w.f32(o.w || 0); w.f32(o.h || 0); break;
      case "layout": {
        w.u8(OP.layout); w.str(o.docId || ""); w.str(o.v || "");
        var pg = o.pages || []; w.u32(o.count || pg.length);
        for (var i = 0; i < pg.length; i++) { w.f32(pg[i][0]); w.f32(pg[i][1]); }
        break;
      }
      case "viewport":
        w.u8(OP.viewport); w.u32(o.page || 0); w.f32(o.frac || 0); w.u32(o.seq || 0); w.u8(o.force ? 1 : 0); break;
      case "docs": {
        w.u8(OP.docs); w.u8(o.following ? 1 : 0); w.str(o.selected || "");
        var L = o.list || []; w.u16(L.length);
        for (var j = 0; j < L.length; j++) { w.str(L[j].id); w.str(L[j].title); }
        break;
      }
      case "pens": {
        w.u8(OP.pens); w.u16(o.active || 0);
        var P = o.list || []; w.u16(P.length);
        for (var k = 0; k < P.length; k++) w.pen(P[k]);
        break;
      }
      case "layers": {
        w.u8(OP.layers); w.u16(o.active || 0);
        var LY = o.list || []; w.u16(LY.length);
        for (var ly = 0; ly < LY.length; ly++) {
          var item = LY[ly];
          w.u8(item.r || 0); w.u8(item.g || 0); w.u8(item.b || 0);
          w.u8(item.visible ? 1 : 0); w.str(item.name || "");
        }
        break;
      }
      case "library": {
        w.u8(OP.library); w.str(o.ws || "");
        var LB = o.list || []; w.u16(LB.length);
        for (var lb = 0; lb < LB.length; lb++) { w.str(LB[lb].id); w.str(LB[lb].title); w.u8(LB[lb].open ? 1 : 0); }
        break;
      }
      case "toc": {
        w.u8(OP.toc); w.str(o.docId || "");
        var TC = o.list || []; w.u16(TC.length);
        for (var tc = 0; tc < TC.length; tc++) {
          var te2 = TC[tc], tp = te2.page == null ? -1 : te2.page;   // 坏书签在对象模型里是 -1
          w.u8(te2.depth || 0); w.u8(tp >= 0 ? 1 : 0);
          w.u32(tp >= 0 ? tp : 0); w.f32(te2.frac || 0); w.str(te2.label || "");
        }
        break;
      }
      // 草稿纸（v8）。open = 当前打开 list 里第几张，0xFFFF = 没开（对象里 -1，同 radial.highlight 惯例）。
      case "scratchpads": {
        w.u8(OP.scratchPads);
        var spo = o.open == null ? -1 : o.open;
        w.u16(spo < 0 ? NO_PAD : spo);
        var SP = o.list || []; w.u16(SP.length);
        for (var sp = 0; sp < SP.length; sp++) {
          var pd = SP[sp];
          w.str(pd.id || ""); w.str(pd.title || "");
          w.u32(pd.page || 0); w.f32(pd.nx || 0); w.f32(pd.ny || 0);
          var bgc = parseColor(pd.bg);
          w.u8(bgc[0]); w.u8(bgc[1]); w.u8(bgc[2]); w.f32(bgc[3]);
          w.u8(patCode(pd.pattern));   // 底纹（v9）
          w.u8(pd.showPage ? 1 : 0);   // 页面底图开关（v10）
        }
        break;
      }
      case "scratchStrokes": {
        // 当前打开那张纸上的全量笔迹。**无 page 字段**——画布不属于任何一页，点集是画布坐标
        // （逻辑点，可负无界，见 PROTOCOL.md 的草稿纸坐标系）。ackRel 语义同 strokes。
        w.u8(OP.scratchStrokes); w.u32(o.ackRel || 0);
        var SS = o.list || []; w.u32(SS.length);
        for (var ss = 0; ss < SS.length; ss++) { w.pen(SS[ss].pen); w.pts(SS[ss].pts, 3); }
        break;
      }
      case "scratchOpen": {
        w.u8(OP.scratchOpen);
        var soi = o.index == null ? -1 : o.index;
        w.u16(soi < 0 ? NO_PAD : soi);
        break;
      }
      case "scratchAdd":
        w.u8(OP.scratchAdd); w.u32(o.page || 0); w.f32(o.nx || 0); w.f32(o.ny || 0);
        break;
      case "scratchPaper": {
        // 改第 index 张纸的纸样（底色 + 底纹）。Mac 判定后回推 scratchpads，两端自然一致。
        w.u8(OP.scratchPaper); w.u16(o.index == null ? 0 : o.index);
        var pc = parseColor(o.bg);
        w.u8(pc[0]); w.u8(pc[1]); w.u8(pc[2]); w.f32(pc[3]);
        w.u8(patCode(o.pattern));
        break;
      }
      case "scratchMove":
        // 图钉页内拖动（0x2E，C→S）：把第 index 张纸的图钉锚点挪到**同页内** (nx, ny)。
        // Mac 钳位 0~1、越界 index 丢弃，经 scratchpads 全量回推（以回推为权威，同 scratchPaper 惯例）。
        w.u8(OP.scratchMove); w.u16(o.index || 0); w.f32(o.nx || 0); w.f32(o.ny || 0);
        break;
      case "scratchPageShow":
        // 页面底图开关（0x2F，C→S）：第 index 张纸要不要垫它锚定的那一页（几何契约见 PROTOCOL.md §4.4）。
        w.u8(OP.scratchPageShow); w.u16(o.index || 0); w.u8(o.show ? 1 : 0);
        break;
      case "scratchDelete":
        // 删第 index 张纸（连同纸上笔迹，0x48，C→S）。Mac 判定 + 落库后回推 scratchpads/scratchStrokes。
        w.u8(OP.scratchDelete); w.u16(o.index || 0);
        break;
      case "scratchRename":
        // 改第 index 张纸的名字（0x49，C→S）。空串 = 回到「草稿纸 N」兜底名。
        w.u8(OP.scratchRename); w.u16(o.index || 0); w.str(o.title || "");
        break;
      case "noteNew":
        // Mac 在环形盘提交「新建文字笔记」后下发（0x3F，S→C）：平板在该页内锚点打开编辑器。
        w.u8(OP.noteNew); w.u32(o.page || 0); w.f32(o.nx || 0); w.f32(o.ny || 0);
        break;
      case "inkCancel": w.u8(OP.inkCancel); break;
      case "strokes": {
        // ackRel：Mac 已连续处理到的该客户端 REL seq，按收件人填（PROTOCOL.md §4.2）。
        // 浏览器不走 UDP，收到的恒为 0，忽略即可——这个字段是给原生客户端分辨中途快照用的。
        w.u8(OP.strokes); w.u32(o.ackRel || 0); var S = o.list || []; w.u32(S.length);
        for (var s = 0; s < S.length; s++) { w.u32(S[s].page || 0); w.pen(S[s].pen); w.pts(S[s].pts, 3); }
        break;
      }
      case "radial": {
        w.u8(OP.radial);
        if (!o.open) { w.u8(0); break; }
        w.u8(1); w.u32(o.page || 0); w.f32(o.cx || 0); w.f32(o.cy || 0);
        var hl = o.highlight == null ? -1 : o.highlight;
        w.u16(hl < 0 ? NO_HL : hl);
        var IT = o.items || []; w.u16(IT.length);
        for (var t2 = 0; t2 < IT.length; t2++) { w.u8(rkindCode(IT[t2].kind)); w.pen(IT[t2]); }
        break;
      }
      case "pressRing": {
        w.u8(OP.pressRing);
        if (!o.on) { w.u8(0); break; }
        w.u8(1); w.u32(o.page || 0); w.f32(o.nx || 0); w.f32(o.ny || 0);
        break;
      }
      case "padGeom": w.u8(OP.padGeom); w.f32(o.pageW || 0); break;
      case "lassoMove":
        w.u8(OP.lassoMove); w.u32(o.page || 0);
        w.f32(o.x0 || 0); w.f32(o.y0 || 0); w.f32(o.x1 || 0); w.f32(o.y1 || 0);
        w.f32(o.dx || 0); w.f32(o.dy || 0);
        w.polyTail(o.poly);   // 尾部可选多边形（PROTOCOL.md §4.1）：缺省 = 老形态字节不变
        break;
      case "lassoScale":
        w.u8(OP.lassoScale); w.u32(o.page || 0);
        w.f32(o.x0 || 0); w.f32(o.y0 || 0); w.f32(o.x1 || 0); w.f32(o.y1 || 0);
        w.f32(o.ax || 0); w.f32(o.ay || 0); w.f32(o.sx || 1); w.f32(o.sy || 1);
        w.polyTail(o.poly);
        break;
      case "layerSelect": w.u8(OP.layerSelect); w.u16(o.index || 0); break;
      case "layerVisible": w.u8(OP.layerVisible); w.u16(o.index || 0); w.u8(o.visible ? 1 : 0); break;
      case "layerAdd": w.u8(OP.layerAdd); break;
      case "scroll": w.u8(OP.scroll); w.u32(o.page || 0); w.f32(o.frac || 0); w.f64(o.t || 0); break;
      case "hover":
        w.u8(OP.hover);
        if (o.phase === "end") { w.u8(PH.end); }
        else { w.u8(PH.move); w.u32(o.page || 0); w.f32(o.nx || 0); w.f32(o.ny || 0); }
        break;
      case "ink":
        w.u8(OP.ink); w.u8(PH[o.phase]);
        // begin 末尾 flags（bit0=line 直线/尺子笔）：见 PROTOCOL.md §4.3。
        if (o.phase === "begin") { w.u32(o.page || 0); w.pen(o.pen); w.pts(o.pts, 3); w.u8(o.line ? 1 : 0); }
        else if (o.phase === "move") { w.pts(o.pts, 3); }
        break;
      case "erase":
        w.u8(OP.erase); w.u8(PH[o.phase]);
        if (o.phase === "move") { w.u32(o.page || 0); w.pts(o.pts, 2); }
        break;
      case "probe":
        w.u8(OP.probe); w.u8(PH[o.phase]);
        if (o.phase === "begin") { w.u32(o.page || 0); w.pts(o.pts, 2); }
        else if (o.phase === "move") { w.pts(o.pts, 2); }
        break;
      case "nack": {
        w.u8(OP.nack); var SQ = o.seqs || []; w.u16(SQ.length);
        for (var q = 0; q < SQ.length; q++) w.u32(SQ[q]);
        break;
      }
      default: return null;
    }
    return w.bytes();
  }

  // ---- decode(ArrayBuffer|Uint8Array) -> object | null ----
  function decode(ab) {
    var r = new Reader(ab);
    if (r.len < 1) return null;
    var op = r.u8();
    switch (op) {
      case OP.auth: return { type: "auth", token: r.str() };
      case OP.authOK: {
        // v1 起带 [u32 session][u16 udpPort]；兼容空 payload（→ 0）。
        if (r.len - r.n >= 6) return { type: "authOK", session: r.u32(), udpPort: r.u16() };
        return { type: "authOK", session: 0, udpPort: 0 };
      }
      case OP.authFail: return { type: "authFail" };
      case OP.ping: return { type: "ping", t: r.f64() };
      case OP.pong: return { type: "pong", t: r.f64() };
      case OP.latency: return { type: "latency", ms: r.f32() };
      case OP.selectDoc: return { type: "selectDoc", id: r.str() };
      case OP.pageTurn: return { type: "pageTurn", dir: r.u8() === 0 ? "prev" : "next" };
      case OP.gotoPage: {
        // 尾部可选 f32 frac：4 字节 payload = 老形态（只跳页，frac 补 0）。
        var gp = r.u32();
        return { type: "gotoPage", page: gp, frac: r.left() >= 4 ? r.f32() : 0 };
      }
      case OP.openDoc: return { type: "openDoc", id: r.str() };
      case OP.mode: return { type: "mode", mode: MODEK[r.u8()] || "note" };
      case OP.pen: return { type: "pen", index: r.u16() };
      case OP.penset: {
        var psa = r.u16(), psn = r.u16(), pslist = new Array(psn);
        for (var psi = 0; psi < psn; psi++) pslist[psi] = r.pen();
        return { type: "penset", list: pslist, active: psa };
      }
      case OP.eraser: return { type: "eraser", size: r.f32(), mode: r.u8(), ring: r.u8() };
      case OP.textNote: return { type: "textNote", id: r.str(), op: r.u8() === 1 ? "delete" : "upsert",
                                 page: r.u32(), nx: r.f32(), ny: r.f32(), text: r.str() };
      case OP.notes: {
        var nn2 = r.u16(), nlist = new Array(nn2);
        for (var nj = 0; nj < nn2; nj++) nlist[nj] = { id: r.str(), page: r.u32(), nx: r.f32(), ny: r.f32(), text: r.str() };
        return { type: "notes", list: nlist };
      }
      case OP.page: return { type: "page", v: r.u32(), index: r.u32(), count: r.u32(), w: r.f32(), h: r.f32() };
      case OP.layout: {
        var docId = r.str(), v = r.str(), count = r.u32(), pages = new Array(count);
        for (var i = 0; i < count; i++) pages[i] = [r.f32(), r.f32()];
        return { type: "layout", docId: docId, v: v, count: count, pages: pages };
      }
      case OP.viewport: return { type: "viewport", page: r.u32(), frac: r.f32(), seq: r.u32(), force: r.u8() === 1 };
      case OP.docs: {
        var following = r.u8() === 1, selected = r.str(), n = r.u16(), list = new Array(n);
        for (var j = 0; j < n; j++) list[j] = { id: r.str(), title: r.str() };
        return { type: "docs", list: list, selected: selected, following: following };
      }
      case OP.pens: {
        var active = r.u16(), pn = r.u16(), plist = new Array(pn);
        for (var k = 0; k < pn; k++) plist[k] = r.pen();
        return { type: "pens", list: plist, active: active };
      }
      case OP.layers: {
        var lya = r.u16(), lyn = r.u16(), lylist = new Array(lyn);
        for (var lyi = 0; lyi < lyn; lyi++) {
          lylist[lyi] = { r: r.u8(), g: r.u8(), b: r.u8(), visible: r.u8() === 1, name: r.str() };
        }
        return { type: "layers", list: lylist, active: lya };
      }
      case OP.library: {
        var lws = r.str(), lbn = r.u16(), lblist = new Array(lbn);
        for (var lbi = 0; lbi < lbn; lbi++) lblist[lbi] = { id: r.str(), title: r.str(), open: r.u8() === 1 };
        return { type: "library", ws: lws, list: lblist };
      }
      case OP.toc: {
        var tdoc = r.str(), tn = r.u16(), tlist = new Array(tn);
        for (var ti = 0; ti < tn; ti++) {
          var tdep = r.u8(), thas = r.u8() === 1, tpg = r.u32(), tfr = r.f32(), tlb = r.str();
          // 坏书签（hasPage=0）→ page = -1：客户端据此渲染成不可点的灰行。
          tlist[ti] = { depth: tdep, page: thas ? tpg : -1, frac: tfr, label: tlb };
        }
        return { type: "toc", docId: tdoc, list: tlist };
      }
      case OP.scratchPads: {
        var spOpen = r.u16(), spn = r.u16(), splist = new Array(spn);
        for (var spi = 0; spi < spn; spi++) {
          var pid = r.str(), ptitle = r.str(), ppage = r.u32(), pnx = r.f32(), pny = r.f32();
          var br = r.u8(), bg = r.u8(), bb = r.u8(), ba = r.f32();
          var ppat = PATK[r.u8()] || "dots";
          var pshow = r.u8() !== 0;   // 页面底图开关（v10）
          splist[spi] = { id: pid, title: ptitle, page: ppage, nx: pnx, ny: pny,
                          bg: "rgba(" + br + "," + bg + "," + bb + "," + ba + ")", pattern: ppat,
                          showPage: pshow };
        }
        return { type: "scratchpads", open: spOpen === NO_PAD ? -1 : spOpen, list: splist };
      }
      case OP.scratchStrokes: {
        var ssack = r.u32(), ssn = r.u32(), sslist = new Array(ssn);
        for (var ssi = 0; ssi < ssn; ssi++) sslist[ssi] = { pen: r.pen(), pts: r.pts(3) };
        return { type: "scratchStrokes", ackRel: ssack, list: sslist };
      }
      case OP.scratchOpen: {
        var soIdx = r.u16();
        return { type: "scratchOpen", index: soIdx === NO_PAD ? -1 : soIdx };
      }
      case OP.scratchAdd:
        return { type: "scratchAdd", page: r.u32(), nx: r.f32(), ny: r.f32() };
      case OP.scratchPaper: {
        var spi2 = r.u16(), qr = r.u8(), qg = r.u8(), qb = r.u8(), qa = r.f32();
        return { type: "scratchPaper", index: spi2,
                 bg: "rgba(" + qr + "," + qg + "," + qb + "," + qa + ")",
                 pattern: PATK[r.u8()] || "dots" };
      }
      case OP.scratchMove:
        return { type: "scratchMove", index: r.u16(), nx: r.f32(), ny: r.f32() };
      case OP.scratchPageShow:
        return { type: "scratchPageShow", index: r.u16(), show: r.u8() !== 0 };
      case OP.scratchDelete:
        return { type: "scratchDelete", index: r.u16() };
      case OP.scratchRename:
        return { type: "scratchRename", index: r.u16(), title: r.str() };
      case OP.noteNew:
        return { type: "noteNew", page: r.u32(), nx: r.f32(), ny: r.f32() };
      case OP.inkCancel: return { type: "inkCancel" };
      case OP.strokes: {
        var sack = r.u32(), sn = r.u32(), slist = new Array(sn);
        for (var s = 0; s < sn; s++) slist[s] = { page: r.u32(), pen: r.pen(), pts: r.pts(3) };
        return { type: "strokes", ackRel: sack, list: slist };
      }
      case OP.radial: {
        if (r.u8() === 0) return { type: "radial", open: false };
        var rp = r.u32(), rcx = r.f32(), rcy = r.f32(), rhl = r.u16(), rn = r.u16();
        var items = new Array(rn);
        for (var ri = 0; ri < rn; ri++) {
          var kind = RKIND[r.u8()] || "pen", pn2 = r.pen();
          pn2.kind = kind; items[ri] = pn2;
        }
        return { type: "radial", open: true, page: rp, cx: rcx, cy: rcy,
                 highlight: rhl === NO_HL ? -1 : rhl, items: items };
      }
      case OP.pressRing: {
        if (r.u8() === 0) return { type: "pressRing", on: false };
        return { type: "pressRing", on: true, page: r.u32(), nx: r.f32(), ny: r.f32() };
      }
      case OP.padGeom: return { type: "padGeom", pageW: r.f32() };
      case OP.lassoMove: {
        var lmPage = r.u32(), lmX0 = r.f32(), lmY0 = r.f32(), lmX1 = r.f32(), lmY1 = r.f32(), lmDx = r.f32(), lmDy = r.f32();
        return { type: "lassoMove", page: lmPage, x0: lmX0, y0: lmY0, x1: lmX1, y1: lmY1, dx: lmDx, dy: lmDy,
                 poly: r.polyTail() };
      }
      case OP.lassoScale: {
        var lsPage = r.u32(), lsX0 = r.f32(), lsY0 = r.f32(), lsX1 = r.f32(), lsY1 = r.f32(),
            lsAx = r.f32(), lsAy = r.f32(), lsSx = r.f32(), lsSy = r.f32();
        return { type: "lassoScale", page: lsPage, x0: lsX0, y0: lsY0, x1: lsX1, y1: lsY1,
                 ax: lsAx, ay: lsAy, sx: lsSx, sy: lsSy, poly: r.polyTail() };
      }
      case OP.layerSelect: return { type: "layerSelect", index: r.u16() };
      case OP.layerVisible: { var lvi = r.u16(), lvv = r.u8() === 1; return { type: "layerVisible", index: lvi, visible: lvv }; }
      case OP.layerAdd: return { type: "layerAdd" };
      case OP.scroll: return { type: "scroll", page: r.u32(), frac: r.f32(), t: r.f64() };
      case OP.hover: {
        var hph = r.u8();
        if (hph === PH.end) return { type: "hover", phase: "end" };
        return { type: "hover", page: r.u32(), nx: r.f32(), ny: r.f32() };
      }
      case OP.ink: {
        var iph = r.u8();
        if (iph === PH.begin) {
          // flags 是 begin 末尾的**可选**字节（老客户端不发）：缺就是 line=0，读完 pts 即止。
          var ib = { type: "ink", phase: "begin", page: r.u32(), pen: r.pen(), pts: r.pts(3) };
          ib.line = ((r.len - r.n >= 1 ? r.u8() : 0) & 1) === 1;
          return ib;
        }
        if (iph === PH.move) return { type: "ink", phase: "move", pts: r.pts(3) };
        return { type: "ink", phase: "end" };
      }
      case OP.erase: {
        var eph = r.u8();
        if (eph === PH.move) return { type: "erase", phase: "move", page: r.u32(), pts: r.pts(2) };
        return { type: "erase", phase: "end" };
      }
      case OP.probe: {
        var pph = r.u8();
        if (pph === PH.begin) return { type: "probe", phase: "begin", page: r.u32(), pts: r.pts(2) };
        if (pph === PH.move) return { type: "probe", phase: "move", pts: r.pts(2) };
        return { type: "probe", phase: "end" };
      }
      case OP.nack: {
        var nn = r.u16(), seqs = new Array(nn);
        for (var qi = 0; qi < nn; qi++) seqs[qi] = r.u32();
        return { type: "nack", seqs: seqs };
      }
      default: return null;   // 未知 opcode：丢弃
    }
  }

  return { OP: OP, encode: encode, decode: decode, PHNAME: PHNAME };
});
