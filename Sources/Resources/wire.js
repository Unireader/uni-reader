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
    layerSelect: 0x26, layerVisible: 0x27, layerAdd: 0x28, gotoPage: 0x29,
    page: 0x30, layout: 0x31, viewport: 0x32, docs: 0x33, pens: 0x34, inkCancel: 0x35, strokes: 0x36,
    radial: 0x37, pressRing: 0x38, notes: 0x39, layers: 0x3A,
    scroll: 0x40, hover: 0x41, ink: 0x42, erase: 0x43, probe: 0x44, padGeom: 0x45, eraser: 0x46,
    lassoMove: 0x47,
    nack: 0x50
  };
  var BRUSH = ["ballpoint", "fountain", "marker", "pencil"];
  var MODEK = ["note", "erase", "page", "lasso"];
  var RKIND = ["pen", "erase", "page"];      // 环形盘扇区类型
  var NO_HL = 0xFFFF;                        // highlight 线上哨兵：无高亮（中心取消区）→ 对象里 -1
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
      case "gotoPage": w.u8(OP.gotoPage); w.u32(o.page || 0); break;
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
      case OP.gotoPage: return { type: "gotoPage", page: r.u32() };
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
        return { type: "lassoMove", page: lmPage, x0: lmX0, y0: lmY0, x1: lmX1, y1: lmY1, dx: lmDx, dy: lmDy };
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
