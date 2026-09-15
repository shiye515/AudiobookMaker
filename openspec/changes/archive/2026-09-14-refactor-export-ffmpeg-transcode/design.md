## Context

整书 M4B 导出现走 AVAssetReader + AVAssetWriter 手工管线（AAC 经 AudioConverter/AQOfflineMixer）。实测长书（8.7h/41 章）导出速度从 26× 实时持续劣化至 ~1.3×：写入器内部 CMBufferQueue 无限膨胀、append 入队成本超线性增长占满单核，编码器线程 99% 时间等待（`sample` 采样实锤，详见 HANDOFF 第 14 节）。应用已内置极简静态 ffmpeg（2.7MB，`scripts/build-ffmpeg.sh`），本变更将整书转码切换到它。

**可行性已全部实测验证**（真实书《李光耀观天下》41 章 / 8.7h 素材）：

- 单条命令完成 concat 拼接 + AAC 编码 + 章节 + 封面 + 元数据，整书用时 **131 秒（239× 实时）**，ffprobe 验证 41 章齐全；
- 已验证命令形态：
  ```
  ffmpeg -y -v error -f concat -safe 0 -i chapters.txt -i meta.txt -i cover.jpg \
    -map 0:a -map 2:v -map_metadata 1 -map_chapters 1 \
    -disposition:v:0 attached_pic -c:v copy -c:a aac -b:a 64k \
    -progress pipe:1 out.m4b
  ```
  其中 `chapters.txt` 为 concat 解复用列表（`file 'file:…wav'` 逐行）、`meta.txt` 为 FFMETADATA（毫秒时间基章节）；
- 封面 jpg/jpeg/png 均以 `-c:v copy` 直拷为 attached_pic（png 需构建含 zlib + png 解码器，已解决）；
- `-progress` 输出 `out_time_ms=`（**单位实为微秒**，ffmpeg 历史命名）与 `speed=`，可解析。

另见 proposal.md 的 Why 与 `audiobook-export` delta 规格（码率档位修正、内置 ffmpeg 依赖、即时硬取消语义）。

## Goals / Non-Goals

**Goals:**

- M4B 整书转码全链路切换到内置 ffmpeg：拼接、编码、章节、封面、元数据一条命令完成。
- 进度精确（`-progress` 解析）、取消即时（进程硬终止）、半产物清理语义与现状一致。
- 构建脚本组件定稿并重建产物（本轮已验证的组件清单固化）。

**Non-Goals:**

- 界面零改动：ExportSheetView、AppStore 导出状态机对外接口（runExport/cancelExport/runID 门卫）一律不动。
- 分章节 M4A 与 WAV 导出路径不变（仍走 AVAssetExportSession / 文件复制）。
- 不改码率策略、不做 MP3、不做后台/断点续导。

## Decisions

### D1. 单命令方案，不再拆"转码 + 注入"两步

concat 解复用器直接消费 WAV 列表，AAC 编码与 FFMETADATA 章节、封面 attached_pic、标题/作者元数据在同一次运行内完成（已验证）。替代现存的 transcodeToM4B + injectChaptersViaFFmpeg 两步流程，消除中间临时文件与第二次进程启动。
*备选*：保留两步（转码后注入）——多一次进程启动与一次全文件流复制，无收益，放弃。

### D2. 进度：`-progress pipe:1` 解析 `out_time_ms`，200ms 节流

ffmpeg 以 key=value 行输出进度；`out_time_ms` 单位实为微秒（历史命名），除以总时长（章节扫描阶段已有的 totalSeconds）得比例，映射到进度条 5%–99% 段（扫描 0–5%，完成 100%）。解析循环按 200ms 节流向 UI 回报，避免逐行洪泛主线程。
**管道防死锁（关键）**：macOS 管道缓冲仅 64KB，长书导出若不实时消费 stdout，ffmpeg 会因管道写阻塞而假死。必须用 `FileHandle.readabilityHandler`（或 AsyncStream）**边跑边读**并按行缓冲解析，绝不允许等进程结束后再读取；stderr 同理（`-v error` 下输出少，但同样实时消费）。
*备选*：解析 stderr 的 `time=` 文本——格式不稳定，放弃。

### D3. 取消 = `withTaskCancellationHandler` 即时 `terminate()` 硬终止

用 Swift Concurrency 原生取消钩子包裹进程等待：

```swift
try await withTaskCancellationHandler {
    // process.run() + 等待 terminationHandler（checked continuation）
} onCancel: {
    process.terminate()   // 上层 cancelExport() 的瞬间同步触发，零轮询零延迟
}
```

相比 200ms 轮询 `Task.isCancelled`：无轮询任务、终止延迟为零；`onCancel` 闭包需非隔离且可重入（幂等：进程已退出时 terminate 无害）。进程退出后依据取消标记抛 `CancellationError` 并删除半成品 outputURL。相比 AVAssetWriter 时代的逐缓冲协作检查，取消延迟从"可能无限"变为即时。
*备选*：定时轮询 `Task.isCancelled`——多一个常驻任务且有轮询延迟，放弃。

### D4. ffmpeg 缺失时 M4B 直接报错（移除静默降级）

内置 ffmpeg 随包必在；`locateFFmpeg()` 仍保留 Homebrew 兜底（开发期）。两者皆无时导出报"未找到内置 ffmpeg 组件"错误，不再产出无章节文件（旧行为让用户误以为成功）。
*备选*：回退 AVAssetWriter 管线——正是要移除的劣化路径，放弃。

### D5. 封面统一 `-c:v copy` attached_pic，动态拼接参数

jpg/jpeg/png 实测均可直拷（png 依赖构建含 zlib + png 解码器，已定稿）。**参数动态拼接（防坑）**：仅当「勾选嵌入封面且封面文件存在」时才追加第三个输入 `-i cover` 与 `-map 2:v -disposition:v:0 attached_pic`；无封面/未勾选时绝不能出现 `-map 2:v`（否则 `Stream map '2:v' matches no streams` 直接失败）。未勾选封面或无封面文件时不映射视频输入。构建组件在脚本中定稿：demuxers（mov/ffmetadata/concat/wav/image2）、muxers（ipod/mov）、decoders（mjpeg/png/pcm_s16le）、encoders（aac/mjpeg）、filters（aresample/aformat/anull）、bsf（aac_adtstoasc）、zlib、file 协议。

### D6. 标题/作者元数据写入 FFMETADATA 头部，不走命令行参数

`;FFMETADATA1` 文件顶部直接写 `title=` / `artist=`（及 album 等），配合 `-map_metadata 1` 生效——完全避开命令行传参对特殊字符（引号、换行、反斜杠）的转义问题，与章节表同文件同生命周期（临时文件 defer 清理）。

### D7. 删除 AVAssetWriter 转码路径，不留双实现

`transcodeToM4B` 整体移除；`runSession` 保留（分章节 M4A 仍在用）。章节参数一致性（24kHz/单声道/Int16）由同源 TTS 管线保证；concat demuxer 对参数不一致会自身报错，导出器捕获后按 `exportFailed` 呈现。
*备选*：保留旧管线做回退开关——双倍维护面且旧路径正是劣化源，放弃。

## Risks / Trade-offs

- [ffmpeg 原生 AAC 编码器音质与 Apple AAC 的差异] → 64kbps 单声道有声书场景差异可忽略；实施时以真实书导出听感验收。
- [-progress 输出行可能混入其他前缀] → 解析仅认行首 `out_time_ms=`/`progress=` 键值对，容忍未知行。
- [concat 列表含特殊字符路径] → 单引号包裹并转义（`'` → `'\''`），与现库路径（含中文/空格）实测已通过。
- [进程终止后临时文件残留] → concat 列表/FFMETADATA/半成品均放临时目录并 defer 清理，沿用现有模式。

## Migration Plan

纯导出器内部重构 + 构建脚本更新，无数据迁移。回滚即恢复旧 transcodeToM4B 实现（git 历史），产物格式与旧版兼容（同为 M4B/AAC）。

## Open Questions

（无。）
