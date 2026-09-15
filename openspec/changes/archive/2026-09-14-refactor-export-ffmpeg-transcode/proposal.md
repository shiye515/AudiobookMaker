## Why

当前整书 M4B 导出用 AVAssetReader + AVAssetWriter 手工管线（软件 AAC 经 AudioConverter/AQOfflineMixer 路径），实测长书导出速度从 26× 实时持续劣化到 ~1.3×，进程 100% CPU 烧在写入器内部缓冲队列管理上，编码器线程反而近乎停滞（macOS 26 长会话状态劣化，见 HANDOFF 第 14 节）。应用已内置极简静态 ffmpeg（`scripts/build-ffmpeg.sh`），其软件 AAC 编码速度可预期（通常数百×实时），且 `-progress` 可输出精确进度、进程可硬终止实现即时取消。应把整书转码整体切换到内置 ffmpeg，彻底绕开 AVAssetWriter 编码管线。

## What Changes

- **整书 M4B 转码改用内置 ffmpeg**：以 concat 解复用器拼接全部章节 WAV（同源 TTS 产出、参数一致），单条 ffmpeg 命令完成 AAC 编码 + 章节标记（FFMETADATA）+ 封面（attached_pic）+ 标题/作者元数据；进度从 `-progress` 输出解析（out_time_ms），映射到现有进度条。
- **取消改为硬终止**：转码进程可被 `terminate()` 即时停止（不再依赖逐缓冲协作检查），取消后清理半成品产物；现有 `cancelExport()` UI 语义不变。
- **构建脚本扩展**：`build-ffmpeg.sh` 增加 concat/wav/image2 解复用器、pcm_s16le 解码器、aac/mjpeg 编码器（此前仅流复制能力），产物仍为静态单文件并随应用打包。
- **界面完全不动**：ExportSheetView、进度显示、按钮语义、AppStore 的导出状态机接口（runExport/cancelExport）均保持不变，仅替换 `AudiobookExporter` 内部实现。
- **码率规格对齐现实**：既有规格的码率档位（96/128/192）已在 AAC 采样率上限修复时改为 32/64（见 HANDOFF 第 14 节），本次在 delta 规格中同步修正。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `audiobook-export`: ①「导出配置面板」需求的码率档位修正为 32/64 kbps（Apple AAC 编码器在 24kHz 单声道源下的实际上限）；②「导出执行」需求补充 M4B 由内置 ffmpeg 转码与注入、ffmpeg 缺失时的降级行为；「取消 SHALL 安全中断」语义升级为即时硬终止并清理半成品。

## Impact

- **代码**：`abm/Services/AudiobookExporter.swift`（`transcodeToM4B` 与 `injectChaptersViaFFmpeg` 重构为基于 `Process` 的 ffmpeg 调用，进度/取消/清理语义保持）；`scripts/build-ffmpeg.sh`（新增组件）；`abm/Tools/ffmpeg` 产物重建。
- **不变**：`ExportSheetView`、`AppStore` 导出状态机对外接口、分章节 M4A 与 WAV 导出路径、导出规格的核心行为（单文件 + 章节 + 封面元数据 + 进度 + 取消）。
- **风险**：ffmpeg 原生 AAC 编码器在 64kbps 单声道的音质与 Apple AAC 差异（实测评估）；极简构建组件遗漏（concat/image2 等需实测验证）；`-progress` 解析需处理进度字段的多行输出格式。
