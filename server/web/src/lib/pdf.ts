// pdf.js 的配置与几个小工具。PDF 经服务器的 `GET …/pdf/<哈希>` 按需分段取（服务器支持 Range），大书不必整本下完才显示。

import * as pdfjs from "pdfjs-dist";
import type { PDFDocumentLoadingTask, PDFDocumentProxy } from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

// 字形表 / 标准字体 / 色彩配置 / wasm（JPEG 2000、JBIG2 等扫描图的解码）：构建时拷到 dist/pdfjs/（vite.config.ts），
// 开发时直接用 node_modules 里的
const extras = import.meta.env.DEV ? "/node_modules/pdfjs-dist/" : "/pdfjs/";

export function openPDF(url: string, token: string): PDFDocumentLoadingTask {
  return pdfjs.getDocument({
    url,
    httpHeaders: { Authorization: `Bearer ${token}` },
    rangeChunkSize: 256 * 1024,
    disableAutoFetch: true,   // 只取看到的页要用的部分
    disableStream: true,
    cMapUrl: extras + "cmaps/",
    cMapPacked: true,
    standardFontDataUrl: extras + "standard_fonts/",
    iccUrl: extras + "iccs/",
    wasmUrl: extras + "wasm/",
    isEvalSupported: false,
  });
}

export interface OutlineNode {
  title: string;
  dest: string | unknown[] | null;
  children: OutlineNode[];
}

export async function loadOutline(pdf: PDFDocumentProxy): Promise<OutlineNode[]> {
  type Raw = { title: string; dest: string | unknown[] | null; items: Raw[] };
  const map = (items: Raw[]): OutlineNode[] =>
    items.map((o) => ({ title: o.title, dest: o.dest, children: map(o.items ?? []) }));
  try {
    return map(((await pdf.getOutline()) ?? []) as Raw[]);
  } catch {
    return [];
  }
}

/**
 * 目录项指向哪一页（从 0 起），能读出纵向位置的再给页内比例（0 = 页顶）与纵坐标 [y]
 * （转正后的页面上、左上原点，单位 pt；扫描页对齐开着时调用方要再转一次）。
 */
export async function resolveDest(
  pdf: PDFDocumentProxy,
  dest: string | unknown[] | null,
): Promise<{ page: number; frac: number; y: number | null } | null> {
  try {
    const explicit = typeof dest === "string" ? await pdf.getDestination(dest) : dest;
    if (!Array.isArray(explicit) || explicit.length === 0) return null;
    const ref = explicit[0];
    let page: number;
    if (typeof ref === "number" && Number.isInteger(ref)) page = ref;
    else if (ref && typeof ref === "object") page = await pdf.getPageIndex(ref as Parameters<PDFDocumentProxy["getPageIndex"]>[0]);
    else return null;

    // [页, {name}, …]：XYZ 的纵坐标在第 4 个，FitH / FitBH 在第 3 个，FitR 取上边（第 6 个）
    const kind = (explicit[1] as { name?: string } | undefined)?.name;
    const top = kind === "XYZ" ? explicit[3] : kind === "FitH" || kind === "FitBH" ? explicit[2] : kind === "FitR" ? explicit[5] : null;
    let frac = 0, y: number | null = null;
    if (typeof top === "number") {
      const vp = (await pdf.getPage(page + 1)).getViewport({ scale: 1 });
      const vy = vp.convertToViewportPoint(0, top)[1];
      y = vy;
      frac = Math.min(1, Math.max(0, vy / vp.height));
    }
    return { page, frac, y };
  } catch {
    return null;
  }
}
