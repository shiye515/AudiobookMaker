## 1. 构建脚本定稿与产物

- [x] 1.1 确认 `scripts/build-ffmpeg.sh` 组件定稿（concat/wav/image2/ffmetadata/mov 解复用、ipod/mov muxer、mjpeg/png/pcm_s16le 解码、aac/mjpeg 编码、aresample/aformat/anull 滤镜、aac_adtstoasc bsf、zlib、file 协议），运行脚本重建，验证：`abm/Tools/ffmpeg -encoders/-demuxers` 包含全部清单且体积 ~2.7MB
- [x] 1.2 验证三类封面路径：jpg 直拷、jpeg 直拷、png 直拷（attached_pic），以真实书 3 章素材各跑一次，ffprobe 确认章节 + 音频 + 封面流齐全
- [x] 1.3 整书测速回归：对 8.7h/41 章真实书跑单命令，确认 ≥200× 实时（对照 AVAssetWriter 管线的 80×→1.3× 劣化）

## 2. 导出器重构（AudiobookExporter.swift）

- [x] 2.1 新增 `runFFmpeg(arguments:) -> (Process, Pipe)` 基础设施：进程启动；stdout/stderr 均 `readabilityHandler` **实时消费**（防 64KB 管道缓冲死锁）并按行缓冲解析；取消经 `withTaskCancellationHandler` 的 `onCancel` 直接 `terminate()`（零轮询零延迟，幂等）
- [x] 2.2 新增 `transcodeBookViaFFmpeg(...)`：组装 concat 列表（单引号转义路径）；FFMETADATA 文件头部写 title/artist + 毫秒时间基章节表（元数据不走命令行参数）；**封面参数动态拼接**——仅勾选且封面存在时才追加 `-i cover` + `-map 2:v -disposition attached_pic`（无封面时不得出现 `-map 2:v`）；解析 `-progress` 的 `out_time_ms`（微秒）映射进度 5%–99%（200ms 节流）；进程被终止时抛 CancellationError，非零退出抛 exportFailed
- [x] 2.3 重写 `exportM4B`：章节扫描（0–5%）→ 单命令转码（5–99%）→ 完成（100%）；移除 `transcodeToM4B` 与 `injectChaptersViaFFmpeg`；取消/失败路径删除半成品 outputURL；ffmpeg 缺失时抛"未找到内置 ffmpeg 组件"错误
- [x] 2.4 确认分章节 M4A 与 WAV 路径零改动，`runSession`/`locateFFmpeg` 保留；全文件 `try Task.checkCancellation()` 语义与 UI（runID 门卫）不变
- [x] 2.5 构建验证：`xcodebuild -project abm.xcodeproj -scheme abm build` 通过且无新增警告

## 3. 回归验证与文档

- [x] 3.1 真实书 M4B 导出：进度条平滑走动（不再卡死）、总耗时与 ffmpeg 直跑一致（8.7h 书 ≈ 2–3 分钟）、产物 ffprobe 章节数正确
- [x] 3.2 取消回归：导出中点「停止导出」→ 1 秒内停止、无半成品残留、提示"已取消导出"；随后导出另一本书产物正确（覆盖原 bug 场景）
- [x] 3.3 Apple Books 验收：新导出 M4B 的章节列表、封面、标题/作者显示正常；听感抽测第 1 章与中间章（ffmpeg AAC vs 原 Apple AAC）
- [x] 3.4 HANDOFF 第 14 节追加重构记录（速度对照 239× vs 1.3×、组件清单、注意事项），OPTIMIZATIONS.md 勾销对应项
