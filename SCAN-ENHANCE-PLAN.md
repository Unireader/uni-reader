# 扫描页增强（出图时处理，不改 PDF）

> 2026-09-23 起。§2 算法版**已落地**（提交 `b966d83`）；§3 AI 模型**只做了调研和样张**，用户同日定：
> **「先记录到文档，暂时不用继续研究」**——以后要接着做，从 §3.5「没做完的」接。

## 1. 起因

用户拿《软件工程 2024 张琼声》扫描版（书上页码 110 = PDF 第 115 页）提的两个问题：
- 文字本身不清楚（扫描约 150~200dpi、JPEG 压缩，字边发虚，还有一圈绿色的彩色杂色）；
- 页面右侧有一条蓝灰色杂色（扫描时书页没压平留下的阴影）。

用户要求：**不修改 PDF，只在渲染时处理**。

## 2. 算法版（已落地）

实现与注意事项写在 `docs/agents/STRUCTURE.md` 的「扫描页增强」一条（`AGENTS.md`「结构要点」速览的指针）和 `Sources/App/ScanEnhance.swift` 文件头，这里只记取舍过程。

- 滤镜链（Core Image）：降噪 → 估纸色（邻域取最亮 + 模糊）→ 原图 ÷ 纸色 → 软色阶（五点色调曲线）→ 轻锐化 → 可选去色；
  「精细处理」时以上都在 2 倍分辨率上做再缩回。
- **第一版用硬色阶（`(x-lo)/(hi-lo)` 截断 + gamma）+ 强锐化，用户嫌「有颗粒感」**。根因三条：字边灰度被硬切成非黑即白（锯齿）；
  锐化放大了 JPEG 噪点；在显示分辨率上直接处理，没有余量把边缘磨平。改成「先降噪 + 软色阶 + 轻锐化 + 2 倍超采样」后用户认可
  （当时的对比样张：A 原图 / B 硬色阶 / C 软色阶 / D C+去色，用户选了 C 这套作默认）。
- 实测（第 115 页，995×1400）：右侧 60 列颜色饱和度 0.0186 → 0.0002（蓝条去干净）；整页处理 70~140ms；
  贴片与整页同位置的差异小于不增强时原本就有的差异（`spike/scan-enhance-look.swift`）。
- **做不到的**：原图没扫到的细节补不回来——字能更黑、边缘更整齐、底色更干净，但本来就糊掉的笔画还是糊的。这正是 §3 要解决的。

## 3. AI 模型调研（2026-09-23，只到样张为止）

### 3.1 候选与筛选（查资料的结论）

| 类别 | 模型 | 许可证 | 结论 |
|---|---|---|---|
| 通用超分 | **Real-ESRGAN**（x2plus / general-x4v3 / anime_6B） | BSD-3 | 有现成 Core ML 版（`hanxiao/real-esrgan-coreml`，522×522 固定输入，fp16），**做了样张** |
| 文档修复 | **DocRes**（CVPR 2024，华南理工；去阴影 / 去底色 / 去模糊 / 二值化 / 去弯曲） | MIT | 只有 PyTorch 版，**做了样张** |
| 文档修复 | GCDRNet、DocShadow（FSENet） | MIT | 未试；DocRes 效果不佳后没必要再试同类 |
| 超分（ANE 专用） | PiperSR（x2，928KB，只用 ANE 算子） | 代码 AGPL-3.0，权重 CC BY 4.0 | 未试；只用照片训练，对扫描字效果未知 |
| 超分 | SwinIR、Swin2SR、HAT、waifu2x（nunif） | Apache-2.0 / MIT | 未试；没有现成 Core ML 版，转换与性能成本高 |
| 文字专用超分 | TextZoom/TSRN、TATT、DiffTSR、MARCONet++ | 各异（MARCONet 仅限非商用） | **排除**：按「识别出的字形」重画笔画，认错就画出一个工整但错误的字；且多为单行小图输入 |
| 扩散 / 生成类 | DocDiff、DocRevive 等 | 各异 | **排除**：同上，会改笔画甚至改写文字 |
| Apple 自带 | `CIDocumentEnhancer`、MetalFX 空间放大、Vision | — | 都不是 AI 超分：前者是传统算法（同我们 §2 一类），MetalFX 是游戏用的插值 + 锐化，Vision 在 macOS 26 没有图像增强接口；`VNDocumentCameraViewController` 原生 AppKit 用不了 |

主要来源：Real-ESRGAN Core ML https://github.com/hanxiao/real-esrgan-coreml（仓库说明里 M3 Ultra 数据：
x2plus 0.12s、general 0.03s、anime_6B 0.15s / 每块 512×512；RRDB 结构 ANE 跑不了，全落在 GPU）；
DocRes https://github.com/ZZZHANG-jx/DocRes（权重另见 HuggingFace Space `qubvel-hf/documents-restoration`，
`checkpoints/docres.pkl` 183MB，`data/MBD/checkpoint/mbd.pkl` 713MB 只给去弯曲用）。

### 3.2 样张结论（用户这台 Mac 实测，第 115 / 110 页，输入 995 宽，输出 1990 宽）

| 版本 | 字 | 笔画有没有改错 | 蓝条 / 彩色杂色 | 每页耗时 |
|---|---|---|---|---|
| 算法版（§2） | 黑、清楚，偏粗 | 没有 | 蓝条去净；绿色杂色要开「黑白」才去掉 | ~0.1s |
| **ESRGAN general** | **最锐利，接近印刷原样** | 放大看未发现 | 绿色杂色没了；**蓝条还在** | ~2.7s |
| **ESRGAN anime_6B** | 很干净，笔画偏细 | 放大看未发现 | 同上 | ~5s |
| ESRGAN x2plus | 有改善但发脏，「聚」字糊成一团 | 有涂抹 | 绿色杂色还在 | ~3s |
| DocRes（四种处理） | 和原图差不多，底色稍白 | 没有 | 蓝条只淡了一点 | 16~77s |

- **DocRes 放弃**：对「字发虚」几乎没帮助，权重 183MB，还慢（那次慢很可能是内存不足在换页，用户机器内存不多，但就算不慢也不值得）。
- **Real-ESRGAN general / anime_6B 值得继续**：只负责让字变清楚、不去底色，正好和算法版互补。
- general / anime_6B 是 **4 倍**模型，样张里放大 4 倍再缩回 2 倍，一半算力白费；x2plus 是唯一的 2 倍模型但效果最差。
- 笔画检查只放大看了「务逻辑聚集到」等少数字，**不是系统性的验证**。

### 3.3 怎么复现样张

- Real-ESRGAN：`spike/esrgan-look.swift`（纯 Swift + Core ML，不需要 Python；分块 522、每块四周 24 像素上下文只取中间，无接缝）。
  模型从上面的 release 下载解压即可（general 2.2MB、anime_6B 7.9MB、x2plus 30MB）。
- DocRes：`spike/docres-look.py`。目录布局：`<试验目录>/docres/`（放 DocRes 的 `inference.py`、`utils.py`、
  `models/restormer_arch.py`、`data/preprocess/crop_merge_image.py` 四个文件 + `checkpoints/docres.pkl` + 本脚本改名 `run.py`）、
  `<试验目录>/in/*.png`（输入页）、`<试验目录>/out/`（输出）。Python 环境（**按项目规矩由用户执行安装**）：
  `uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python torch torchvision numpy opencv-python-headless scikit-image scipy einops`。
  脚本已绕开两处 Mac 上跑不了的地方：顶层 import 的去弯曲模块（换成空壳，不需要 `mbd.pkl`）、官方 `model_init` 写死 `cuda:0`。
- 输入页用 `PageBitmap.render` 按 2 像素/pt 渲染；对照的算法版用 `PageBitmap.renderEnhanced(…, pixelWidth: 1990, …)`。

### 3.4 接进 App 的话要解决的（未设计，只列问题）

- **不能同步出图**：每页 2~5 秒。要后台逐页处理，先显示算法版、AI 版好了再替换（符合阅读区「只替换不清空」）；结果进磁盘缓存。
- **串联顺序**：大概率是「ESRGAN 放大 → 算法版去底色」，还没出过样张。
- **高倍贴片**：放大超过基图上限后走贴片，AI 版怎么配合（整页先算好一张大图再切？贴片单独推理？）要另外设计。
- **模型体积与许可**：general 2.2MB / anime_6B 7.9MB，BSD-3，打进 App 包问题不大；需在关于页列出许可证。
- **内存**：用户机器内存不多，推理要限流（一次一页），别和阅读区出图抢。
- 能不能只在「放大阅读」时才用（fit 宽度下 2 像素/pt 算法版已经够看），值得先问用户。

### 3.5 没做完的（接着做从这里开始）

1. 出「ESRGAN general → 算法版去底色」串联样张，用户看效果；
2. 挑更多页（尤其字最糊的页）做笔画正确性的系统检查；
3. 想省一半算力：找或自己转一个 general 结构的 **2 倍**模型（SRVGGNetCompact，coremltools 转换）；
4. 效果满意后再写 App 接入方案（§3.4）并与用户确认——**改出图流程前必须先确认方案**（`AGENTS.md` 红线）。
