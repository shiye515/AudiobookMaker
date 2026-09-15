## Context

M0 spike（`abm/SpikeRunner.swift`）已验证完整调用链：本地权重加载（`fromPretrained` + cacheDir，文件齐全不联网）→ CAM++ 加载 → warmUp → mp3 解码下混 → `extractVoiceProfile`（0.73s/个）→ `synthesize(language: "chinese")`（RTF 0.882）→ 手写 WAV → `AVAudioPlayer` 播放。speech-swift 锁 commit `d655076`（无 release），工程 Debug 配置已关 App Sandbox。技术文档 `docs/cosyvoice-tts-app.md` 第 4 章给出目标架构；本设计按 MVP 范围裁剪。

## Goals / Non-Goals

**Goals:**

- 按 4.2/4.3 章建立引擎隔离层与状态机，UI 不直接接触框架类型
- 复用 spike 已验证调用链，实现四控件 MVP 界面与播放控制
- 音色档案懒加载 + 进程内缓存，避免 10 个音色全量预提取

**Non-Goals:**

- 用户导入音色（已确认砍掉）
- 流式合成/流式播放（框架 `synthesizeStream` 是假流式，整段播放）
- 权重变体切换（4bit/8bit）、情感 instruct UI、多说话人对话（M3）
- 云 API 引擎（M4）；但协议设计保留扩展点
- Bundle 打包权重资产（2.1 GB 打包不现实，M1 保持读仓库路径，分发策略后议）
- WAV 文件导出/保存（M2）

## Decisions

1. **引擎协议收口所有框架调用**：`TTSEngine` 协议（`initialize` / `synthesize` / 状态）+ 唯一实现 `SoniqoCosyVoiceEngine`。理由：框架 0.0.x 无 tag，API 随时可能变；升级只改适配层。备选（UI 直接 import CosyVoiceTTS）被否——散落调用会让未来换引擎（M4 云 API）变成全局重构。

2. **状态机用 `@Observable` + 枚举状态**：`ModelStateManager` 持有 `EngineState` 枚举（uninitialized / loading(progress) / ready / failed(Error)），SwiftUI 直接驱动按钮禁用与提示。不用 Combine/async 流——单窗口单状态源，`@Observable` 最省代码。

3. **去掉播放按钮，合成结果落盘 + 目录访问**：用户反馈变更（2026-09-13）：播放按钮移除；合成成功后 WAV（16-bit PCM / 24 kHz / 手写 44 字节 header，spike 已验证）写入 `~/Library/Application Support/abm/audio/`（文件名 `时间戳-音色名.wav`），界面提供「打开音频目录」按钮（`NSWorkspace.open` 在访达打开）。生成运行细节（音色/时长/耗时/RTF/缓存命中/输出路径/错误）追加写入 `~/Library/Application Support/abm/logs/abm.log`，界面提供「打开日志目录」按钮。不引入 `AVAudioEngine`/`AVAudioPlayer`——App 内不再负责播放，用户用系统播放器试听落盘文件。

4. **音色 = 结构化清单，从打包 JSON 解码**：`VoiceLibrary` 读取随 target 打包的 `audiobook_voices.json`（新增 `docs/sample` 的 mp3 + JSON 为 target resources），每条 `{name, trait, audioFile, text}`；`text` 直接作 referenceTranscript。档案缓存 = 引擎内字典 `[voiceId: CosyVoiceVoiceProfile]`，首次选中合成前提取。

5. **并发模型：单后台 Task 串行**：模型非线程安全（源码警告），`synthesize`/`extractVoiceProfile` 是同步阻塞调用，放到 `Task.detached`/nonisolated 后台执行，结果回主线程刷状态。不建 actor 队列、不做多实例并发——MVP 只需"同时一个任务"。

6. **模型路径可配置注入**：路径常量收敛到一处（当前指向仓库 `docs/models/`），不 hardcode 散落。未来改 Bundle/Application Support 只动一处。

## Risks / Trade-offs

- [框架 API 无 tag 可能变动] → 已锁 commit `d655076`；调用全部收口适配层，升级改动面可控
- [RTF 0.88 略慢于实时] → MVP 可接受；长文本合成时间长，忙碌态 UI 必须清晰；后续可在 Release 配置下复测
- [峰值内存 ~7.2 GB] → MLX 缓存策略所致；MVP 单次合成场景可接受，长会话观察（M2 再加释放策略）
- [Debug 关沙箱] → 资产进 Bundle 后可重开；M1 范围内保持现状，在代码中注明
- [整段合成无首包反馈] → 忙碌指示 + 完成显示输出文件信息；真流式等框架支持后再评估
- [`docs/sample/longlaobo_v3.mp3` 31.8s 略超 5–30s 推荐上限] → 10 个音色照常入库，实测合成异常再裁剪

## Migration Plan

纯新增功能，无数据迁移。2026-09-13 用户反馈变更：移除播放按钮与 `AudioPlayer`，新增音频/日志落盘与目录访问（详见 Decisions 3）。回滚 = 还原对应文件。

## Open Questions

（无）
