// 二进制线格式编解码器的 ESM 适配。
// 单一真源是 Sources/Resources/wire.js（契约 PROTOCOL.md；node spike 测试与 Swift WireCodec.swift
// 的字节级对齐都以它为准，勿复制勿改）——这里原样执行它的 UMD 包装，导出它挂到 self 上的 Wire。
// @ts-ignore 协议真源是纯 JS UMD，无类型声明；形状由下面的 WireCodec 接口刻画
import "../../../Sources/Resources/wire.js";

export interface WireCodec {
  OP: Record<string, number>;
  PHNAME: string[];
  encode(o: unknown): ArrayBuffer | null;
  decode(b: ArrayBuffer): unknown;
}

export const Wire: WireCodec = (self as unknown as { Wire: WireCodec }).Wire;
