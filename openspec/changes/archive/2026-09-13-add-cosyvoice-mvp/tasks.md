## 1. 资产与工程准备

- [x] 1.1 把 `docs/sample/audiobook_voices.json` 与 10 个 `*.mp3` 加入 `abm` target 的 resources（pbxproj 或文件同步组配置），构建后确认 Bundle 内可读：`xcodebuild build` 后在产物 `.app/Contents/Resources/` 下可见这些文件
- [x] 1.2 建立模型路径常量文件（一处收敛：仓库 `docs/models/` 下两个目录 + sample 资源定位），验证路径存在性断言可通过

## 2. 引擎层（Core）

- [x] 2.1 定义 `TTSEngine` 协议（状态、initialize(progress:)、synthesize(text:voice:)）与 `EngineState` 枚举，编译通过即验证
- [x] 2.2 实现 `SoniqoCosyVoiceEngine`：从 spike `SpikeRunner.swift` 搬入已验证调用链——本地权重加载（fromPretrained + cacheDir，progressHandler 映射到状态机）、CAM++ 加载、warmUp；验证：初始化后状态到 ready，离线（可断网）完成
- [x] 2.3 实现 `synthesize(text:voice:)`：懒提取音色档案（首次 0.73s 量级）+ 进程内字典缓存 + `language: "chinese"` 整段合成；验证：同一音色第二次合成不重新提取（日志/计时可见），返回 24 kHz [Float]
- [x] 2.4 串行化保障：合成进行中拒绝新请求（返回忙碌错误而非并发执行）；验证：快速双击不崩溃、状态机不被破坏

## 3. 播放与音色库

- [x] 3.1 实现 `AudioPlayer`：合成结果写 16-bit PCM WAV（24 kHz，手写 header）到临时目录，`AVAudioPlayer` 播放/停止/播放结束回调；验证：播放可听到、stop 立即停止、结束后状态复位
- [x] 3.2 实现 `VoiceLibrary`：从打包 JSON 解码 10 个音色 `{name, trait, audioFile, text}`，暴露列表；验证：解码恰好 10 条且 mp3 文件均存在

## 4. UI 与状态机

- [x] 4.1 实现 `ModelStateManager`（@Observable 状态机：未初始化/加载中(进度)/就绪/出错），驱动初始化按钮与状态显示；验证：预览或运行中状态流转正确，失败后可重试
- [x] 4.2 改写 `ContentView` 为四控件 MVP 界面：初始化按钮、状态、音色下拉（名称+特质）、多行文本框、合成按钮、播放/停止按钮；未就绪时合成/播放禁用；验证：运行 App 肉眼核对布局与禁用逻辑
- [x] 4.3 忙碌态与空文本：合成中禁用合成按钮 + 显示忙碌提示，完成恢复；空文本点击不合成并提示；验证：手动操作两条路径
- [x] 4.4 错误反馈：初始化/提取/合成错误显示为可读信息，按钮复位可重试；验证：模拟一次失败（如改错权重路径）界面有错误提示且可恢复
- [x] 4.5 移除 spike 自动运行逻辑（`SpikeRunner.swift` 删除或仅留参考），App 启动直接进 MVP 界面；验证：启动无 spike 日志、无自动合成

## 5. 端到端验收

- [x] 5.1 全流程验收：启动 → 初始化（进度可见）→ 选龙妙音色 → 输入中文文本 → 合成（忙碌态）→ 点击播放出声 → 停止；对照 specs 三个能力逐条核对场景，实测值（加载/提取/合成耗时）记录到交接文档

## 6. 用户反馈变更：去播放、落盘 + 日志（2026-09-13）

- [x] 6.1 移除播放按钮与 `AudioPlayer.swift`；`TTSEngine.synthesize` 返回值扩展为含 `profileFromCache` 的结果结构；验证：编译通过，UI 无播放控件
- [x] 6.2 新增输出目录与日志：`AppPaths` 增加 `~/Library/Application Support/abm/{audio,logs}` 与初始化函数；`OutputManager` 负责 WAV 时间戳落盘、日志追加、访达打开目录；验证：一次合成后 audio 目录出现 WAV、logs/abm.log 出现含 RTF/缓存命中的条目
- [x] 6.3 UI 改造：合成按钮行去掉播放、完成后界面显示输出文件信息；头部新增「打开音频目录」「打开日志目录」按钮；验证：两个按钮在访达打开对应目录，界面各场景符合 synthesis-ui spec

## 7. 用户反馈变更：文件重名/遗漏修复 + 日志加详（2026-09-13）

- [x] 7.1 WAV 文件名改为 `毫秒时间戳-runID-音色名.wav`（绝不重名、不静默覆盖），写入改原子操作（Data.write(.atomic)），消除同秒覆盖导致的"遗漏"与中途退出残缺文件；验证：编译通过，spec synthesis-ui 已同步
- [x] 7.2 日志加详：每条日志带 pid + 毫秒时间戳；每次生成分配 run ID 串联「合成开始→参考音频解码→档案提取→模型合成→WAV 落盘→完成/失败」全链路，含各阶段耗时与输出字节数；应用启动记录 pid（多实例排查）；验证：构建通过，日志格式见 OutputManager/ModelStateManager

## 8. 用户反馈变更：长文本分段合成（2026-09-13）

- [x] 8.1 调研确认：上游 CosyVoice 前端按句切分逐段合成（frontend.py split_paragraph + 推理循环），speech-swift 未实现该前端，超长单次合成导致段尾丢失/内存膨胀/无进度
- [x] 8.2 新增 `TextChunker`（句末标点切句、短句合并至 ~50 字、超长句硬切 120 字），独立脚本验证切分无字符丢失
- [x] 8.3 引擎改为分段循环合成：段间插入 150ms 静音、逐段计时进日志 `[seg i/N]`、空段（0 采样）记录告警并跳过不中断；协议增加 onSegment 进度回调
- [x] 8.4 UI 合成按钮实时显示分段进度（"合成中…（第 i/N 段）"）；验证：构建通过

## 9. 应用图标（2026-09-13）

- [x] 9.1 CoreGraphics 脚本绘制 1024×1024 主图标（靛紫渐变 squircle + 白色声波条），存入 AppIcon.appiconset（单尺寸格式）
- [x] 9.2 发现 Xcode 26 同步组不编译 Assets.xcassets（actool 从未运行），改走传统 .icns 方案：iconutil 生成 `abm/Resources/AppIcon.icns`（随同步组自动打包）+ `abm/Info.plist`（CFBundleIconFile=AppIcon，与生成内容合并，INFOPLIST_KEY_CFBundleIconFile 不被支持故弃用）；验证：包内 Resources/AppIcon.icns 存在且 Info.plist 引用正确
