// 二进制线格式编解码器的 ESM 适配。
// 单一真源是 Sources/Resources/wire.js（契约 PROTOCOL.md；node spike 测试与 Swift WireCodec.swift
// 的字节级对齐都以它为准，勿复制勿改）——这里原样执行它的 UMD 包装，导出它挂到 self 上的 Wire。
import "../../../Sources/Resources/wire.js";

export const Wire = self.Wire;
