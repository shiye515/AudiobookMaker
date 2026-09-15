## Why

M0 spike 已验证 speech-swift（锁定 commit `d655076`）在本机可出声、RTF ≈ 0.88，本地 CosyVoice3 路线可行。但当前仓库只有 spike 代码，没有可用的产品功能——用户需要一个能真正操作的 macOS App：初始化模型、选音色、输入文本、合成并播放。

## What Changes

- 新增 `TTSEngine` 协议 + `SoniqoCosyVoiceEngine` 适配层：所有对 `CosyVoiceTTS` 框架的调用收敛到这一层（框架无 release，锁 commit 升级时只改这里）
- 新增模型初始化状态机（未初始化 → 加载中 → 就绪 / 出错），驱动"初始化模型"按钮与状态显示；权重从本地 `docs/models/` 目录加载，文件齐全不联网
- 新增内置音色库：固定 10 个有声书音色（`docs/sample/audiobook_voices.json` + mp3，随 App 打包），**不支持用户导入**；音色档案按选中懒提取 + 进程内缓存（spike 实测单个 0.73s）
- 新增 MVP 界面：初始化模型按钮、模型状态、音色下拉框、多行文本输入框、合成按钮（合成期间禁用 + 忙碌提示）；合成结果 WAV 落盘，提供「打开音频目录」「打开日志目录」按钮（生成细节写日志）。**无播放按钮**（2026-09-13 用户反馈变更，App 内不做播放）
- 替换 spike 界面与 `SpikeRunner.swift` 自动运行逻辑（已验证的调用链搬进适配层）
- 保持 Debug 关沙箱现状；权重/音频资产路径通过配置注入，M1 不做 Bundle 打包迁移

## Capabilities

### New Capabilities

- `tts-engine`: 模型初始化与引擎状态——本地权重加载、初始化状态机、合成入口（中文显式指定、整段合成非流式）
- `voice-library`: 内置音色库——10 个有声书音色的清单展示、懒加载音色档案与缓存
- `synthesis-ui`: 合成界面与播放——四控件布局、忙碌态按钮禁用、合成结果 WAV 落盘与播放/停止

### Modified Capabilities

（无——项目尚无任何主规格）

## Impact

- **代码**：`abm/`（新增 Core 层 `TTSEngine.swift`、`SoniqoCosyVoiceEngine.swift`、`ModelStateManager.swift`、`VoiceLibrary.swift`、`AudioPlayer.swift`；改写 `ContentView.swift`、`abmApp.swift`；删除 spike 自动运行逻辑）
- **工程**：`abm.xcodeproj` 不新增依赖（SPM 已锁 `d655076`）；Debug 配置保持 `ENABLE_APP_SANDBOX = NO`
- **依赖**：无新增；`docs/sample/` 10 个 mp3 + JSON 需加入 target resources
- **无破坏性变更**（从空白到首个可用版本）
