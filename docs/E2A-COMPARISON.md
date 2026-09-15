# abm vs ebook2audiobook 对比报告

> 2026-09-14 · 基于 E2A 仓库 main 分支（README + lib/core.py 4389 行核心实现）与 abm 当前代码
> 用途：取长补短评估，未改任何代码

## 一、定位对比

| | **abm（本仓库）** | **ebook2audiobook（E2A）** |
|---|---|---|
| 定位 | macOS 原生有声书工作台（书架→合成→导出全流程） | 跨平台电子书转有声书**转换器**（一次性转换工具） |
| 技术栈 | Swift 6 + SwiftUI + MLX（Apple Silicon 原生推理） | Python + PyTorch（CPU/CUDA/ROCm/MPS/XPU）+ Gradio Web UI |
| TTS 引擎 | CosyVoice3（MLX 量化，单一引擎） | XTTSv2/Bark/VITS/Fairseq/Tacotron2/YourTTS 等 8 种，可换自定义模型 |
| 格式输入 | EPUB（自研解析器） | 20+ 格式：**Calibre ebook-convert 统一转 EPUB** 后再解析 |
| 语言 | 中文（CosyVoice3 中文质量高） | 1158 种语言（Fairseq MMS），自带翻译（argostranslate） |
| 依赖重量 | 零 Python，内置 2.7MB 静态 ffmpeg | Calibre + PyTorch + ebooklib + stanza NLP + Gradio 等重依赖 |
| 许可 | 私有 | GPL-3.0（故其 XTTS 微调模型等组件不能直接抄进本仓库） |

## 二、E2A 值得借鉴的点（按价值排序）

### 1. Calibre 桥：低成本解锁 PDF/MOBI/AZW3 等全部格式 ⭐⭐⭐
E2A 对非 EPUB 输入一律 `ebook-convert --chapter-mark=pagebreak` 先转 EPUB，再进统一解析管线。abm 若检测系统装有 Calibre，导入 PDF/MOBI 等格式时先转 EPUB 再走现有管线——**自研 EPUB 解析器零冲击**，格式支持面一步到位。EPUB 主路径不变（我们自己的解析器质量更高，见下）。

### 2. 文本规范化（TN）前置 ⭐⭐⭐
E2A 用 stanza NLP 做日期/数字/罗马数字→读法的显式转换（如 `1643` → "sixteen forty-three"，`第三章` 罗马数字变体等），再喂 TTS。CosyVoice3 自带部分前端规范化，但**中文年份/数字/标点读法的正确率值得实测**——若有短板，在 TextChunker 之前加一层轻量中文 TN 是提升听感质量性价比最高的一步。

### 3. 合成前文本编辑 ⭐⭐⭐
E2A 的流程是三段式：提取 → **用户在 Web UI 里逐块编辑/勾选保留**（block editor，可改文本、丢弃版权页/广告块）→ 合成。abm 现在是导入即入队。可在导入完成页/书籍详情加"章节文本预览与编辑"（数据已有：text/chN.txt），解析瑕疵不用等合成完才发现。

### 4. 更丰富的导出元数据 ⭐⭐
E2A 的 FFMETADATA 写入 title/artist/**language/publisher/published(year)/ISBN/ASIN**。abm 目前只写 title/artist/chapters——OPF 解析钩子已有（PackageDocumentDelegate），补 language/publisher/date/ISBN 提取并透传到导出即可，Apple Books 的图书信息卡更完整。

### 5. audiobookshelf 推送集成 ⭐⭐
E2A 支持导出后自动上传到自建 audiobookshelf 服务器（fetch_libraries + upload API）。对自建 ABS 的用户是强需求；实现薄（REST + API token）。

### 6. 文本内标记（SML）⭐
`[break]`/`[pause:N]`/`[voice:路径]` 支持在正文里控制停顿与多音色切换（对话书场景）。CosyVoice3 本身支持 SSML 类标记，可在 TextChunker 之上做一层标记透传/映射——对话书多音色是差异化方向，但需先验证 CosyVoice3 的标记支持面，列为远期。

### 7. 输出格式多样性 ⭐
E2A 输出 10 种格式。abm 现有 M4B/分章 M4A/WAV；内置 ffmpeg 可零成本再加 **FLAC/ALAC**（原生编码器，LGPL 路线内）。MP3 仍不可行（无原生编码器、libmp3lame 是 GPL 外部库）。

### 8. 进度恢复的"重对齐"思路 ⭐
E2A 断点恢复做了块级 + 句级双层，且当文本块被编辑后用**文本相似度（阈值 0.6）重新对齐已有音频进度**（`align_blocks`/`remap_resume`）。abm 的分段断点已覆盖崩溃恢复，但"文本编辑后保留已完成音频"的场景（配合上面第 3 点的文本编辑）将来可参考其对齐思路。

## 三、abm 已领先、应保持的

1. **章节目录语义**：E2A 代码头注释自认 "CHAPTER ≠ real chapter"——他们按 ebooklib 文档块切分，**没有目录树概念**，更无锚点级切分。abm 正在做的节级拆分（`add-section-level-chapter-split`，目录树 + 锚点 + 层级链元数据）在这点上**超越 E2A**。
2. **推理效率与中文质量**：MLX on Apple Silicon + CosyVoice3 的中文表现 vs E2A 在 Mac 上走 MPS/CPU 跑 XTTS（慢且中文一般）。abm 实测 80×→239× 实时的导出速度、秒级分段合成。
3. **全书工作台**：书架/批量队列/音色中心/悬浮播放条/导出面板 vs E2A 的单次转换表单。abm 有断点续传、显存治理、失败重试、逐章音色覆盖。
4. **工程纪律**：OpenSpec 规格驱动、内置静态 ffmpeg（无 Homebrew 依赖）、零 Python。E2A 首次安装要装 Calibre + 数 GB Python 依赖。
5. **导出健壮性**：双方都用 FFMETADATA + ffmpeg（英雄所见），但 abm 的进度文件轮询、即时硬取消、内置组件版本锁定是自洽闭环。

## 四、建议（不实现，仅记录）

| 优先级 | 事项 | 归属建议 |
|---|---|---|
| 高 | 实测 CosyVoice3 中文数字/年份/日期读法，不行则加轻量中文 TN | 新提案（合成质量） |
| 高 | 补充导出元数据（language/publisher/year/ISBN） | 新提案（小，可并入其他导出迭代） |
| 中 | Calibre 桥（检测存在性，可选格式扩展） | 新提案（导入格式扩展） |
| 中 | 章节文本预览/编辑（合成前） | 新提案（工作流增强，需 UI 规格） |
| 低 | audiobookshelf 推送、FLAC 输出、SML 标记、进度重对齐 | backlog 远期 |

## 五、结论

两者定位不同：E2A 是"什么书都能吃"的跨平台转换器，靠 Calibre 与多引擎换广度，代价是重依赖与平庸的单语言体验；abm 是深耕 Apple Silicon + 中文有声书的原生工作台，深度（速度/质量/工作台）领先、广度（格式/语言/引擎）落后。最有价值的三个借鉴：**Calibre 桥解格式广度、TN 实测保中文读法质量、合成前文本编辑补工作流短板**——均不触碰既有规格核心行为，可各自走 OpenSpec 小提案推进。
