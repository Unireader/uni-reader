// 页面从哪来（方案 §11）：两种显示方式共用同一个阅读视图（`viewer.ts`），视图只认这里的接口。
// - `PdfSource`：浏览器里用 pdf.js 加载 PDF、画页（W1 起的做法）。
// - `ImageSource`：服务器用 MuPDF 画好 JPEG，按需要的宽度取（各页尺寸打开时一次给齐，不用加载 pdf.js）；
//   扫描页最多按扫描图本身的宽度要，再宽也不会更清楚；高分辨率扫描最多要一半（画布照样按屏幕的像素，图拉大画上去）。
// 两种都画到同一块画布上（白底、扫描页对齐的变换照套），所以笔迹、高亮、书写都不用分两套。

import type { PDFDocumentProxy, RenderTask } from "pdfjs-dist";
import { authFetch, errorOf, pageImageURL } from "./api";

export interface PageSize { w: number; h: number }

export interface RenderJob { promise: Promise<void>; cancel(): void }

export interface PageSource {
  readonly count: number;
  /** 各页显示尺寸（pt）都已知就给（服务器出图）；不知道 = null（pdf.js 边画边量） */
  readonly sizes: PageSize[] | null;
  pageSize(i: number): Promise<PageSize>;
  /**
   * 把第 [i] 页按 [scale]（像素 / pt）画到 [canvas] 上（画布尺寸调用方定好）；[transform] = 扫描页对齐的变换（作用在像素上），
   * [raw] = 对齐参数里记的原始页尺寸（变换以它为准；pdf.js 自己知道页多大，用不着）。取消后 promise 以「取消」结束（`isCancel`）。
   */
  render(i: number, scale: number, canvas: HTMLCanvasElement, transform?: number[], raw?: PageSize): RenderJob;
  /** 这一页的画布收回了：能放的放掉 */
  release(i: number): void;
}

/** 取消的错误：调用方不当错误报。 */
export function isCancel(e: unknown): boolean {
  const name = (e as { name?: string } | null)?.name;
  return name === "RenderingCancelledException" || name === "AbortError";
}

function cancelled(): Error {
  const e = new Error("cancelled");
  e.name = "AbortError";
  return e;
}

export class PdfSource implements PageSource {
  readonly count: number;
  readonly sizes = null;

  constructor(private pdf: PDFDocumentProxy) {
    this.count = pdf.numPages;
  }

  async pageSize(i: number): Promise<PageSize> {
    const vp = (await this.pdf.getPage(i + 1)).getViewport({ scale: 1 });
    return { w: vp.width, h: vp.height };
  }

  render(i: number, scale: number, canvas: HTMLCanvasElement, transform?: number[]): RenderJob {
    let task: RenderTask | null = null;
    let stop = false;
    const promise = (async () => {
      const page = await this.pdf.getPage(i + 1);
      if (stop) throw cancelled();
      task = page.render({ canvas, viewport: page.getViewport({ scale }), transform });
      await task.promise;
    })();
    return { promise, cancel: () => { stop = true; task?.cancel(); } };
  }

  release(i: number) {
    this.pdf.getPage(i + 1).then((p) => p.cleanup()).catch(() => {});
  }
}

/** 服务器出的宽度档（同 `PageImages.widths`）：要多宽就往上取一档。 */
const WIDTHS = [480, 720, 960, 1280, 1600, 2048, 2560, 3200];

export function widthBucket(px: number): number {
  return WIDTHS.find((w) => w >= px) ?? WIDTHS[WIDTHS.length - 1];
}

/** 扫描图超过这么宽就最多要一半（同 `PageImages.halveAbove`）。 */
const HALVE_ABOVE = 4000;
/** 要的那一档离上限不到两成就直接按上限要（同 `PageImages.nearLimit`）：放大缩小共用一张，不再各画一份几乎一样大的。 */
const NEAR_LIMIT = 1.2;

/** 扫描页最多画多宽（同 `PageImages.scanLimit`：高分辨率扫描取一半再少 4 像素，MuPDF 这样才按一半解原图、快一倍）。 */
export function scanLimit(native: number): number {
  return native > HALVE_ABOVE ? Math.floor(native / 2) - 4 : native;
}

/**
 * 向服务器要多宽：按档；扫描页最多按 [scanLimit] 要，离上限不到两成的直接按上限要（[native] = 扫描图本身多宽，0 = 不是扫描页）——
 * 服务器那边也是这样定的（`PageImages.renderWidth`），这里先定好，放大缩小时地址不变，浏览器缓存的那张接着用。
 */
export function requestWidth(px: number, native: number): number {
  const b = widthBucket(px);
  if (native <= 0) return b;
  const limit = scanLimit(native);
  return b * NEAR_LIMIT >= limit ? widthBucket(limit) : b;
}

export class ImageSource implements PageSource {
  readonly count: number;
  readonly sizes: PageSize[];
  private native: number[];

  constructor(private ws: string, private hash: string, pages: number[][]) {
    this.sizes = pages.map(([w, h]) => ({ w: w > 0 ? w : 595, h: h > 0 ? h : 842 }));
    this.native = pages.map((p) => (p[2] ?? 0) > 0 ? p[2] : 0);
    this.count = this.sizes.length;
  }

  async pageSize(i: number): Promise<PageSize> { return this.sizes[i]; }

  render(i: number, scale: number, canvas: HTMLCanvasElement, transform?: number[], raw?: PageSize): RenderJob {
    const ac = new AbortController();
    const promise = (async () => {
      const { w, h } = raw ?? this.sizes[i];
      const rw = w * scale, rh = h * scale;
      // 地址里带内容哈希、页、宽：服务器让浏览器长期缓存，翻回来不重新下载
      const r = await authFetch(pageImageURL(this.ws, this.hash, i, requestWidth(Math.ceil(rw), this.native[i])), { signal: ac.signal });
      if (!r.ok) throw await errorOf(r);
      const bmp = await createImageBitmap(await r.blob());
      if (ac.signal.aborted) {
        bmp.close();
        throw cancelled();
      }
      try {
        const ctx = canvas.getContext("2d");
        if (!ctx) throw new Error("canvas");
        ctx.fillStyle = "#fff";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        if (transform) ctx.setTransform(transform[0], transform[1], transform[2], transform[3], transform[4], transform[5]);
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(bmp, 0, 0, rw, rh);
      } finally {
        bmp.close();
      }
    })();
    return { promise, cancel: () => ac.abort() };
  }

  release() {}
}
