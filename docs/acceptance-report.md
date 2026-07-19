# AudiobookMaker 发布验收报告

日期：2026-07-19
环境：macOS 26.5.2（x86_64 MacBook Pro）、Xcode 26 工具链
真实样本：`/Users/shiye/Downloads/李光耀论中国与世界_李光耀.epub`

## 结论

基础应用的 Release App 已构建并通过签名校验。`adopt-sherpa-kokoro` 变更新增随 App 分发的 sherpa-onnx 1.13.2 与 ONNX Runtime 1.24.4 通用动态库；Kokoro 权重仍不进入 App bundle。

生产转换路径支持 Apple `AVSpeechSynthesizer` 与 sherpa-onnx/Kokoro。确定性 mock 仅用于自动化测试；Kokoro 使用通用 CPU 后端，支持 Intel 与 Apple 芯片，模型权重在安装 App 后单独下载。

## 全量自动化测试

最新单元/集成结果包：`build/FullTest-Kokoro-Latest-Units-v6.xcresult`

UI 结果包：`build/FullTest-Kokoro-Latest-UI-v13.xcresult`

- 最新源码 81 个 Swift Testing 单元/集成测试通过，0 失败
- 8 个 XCUITest 通过，0 失败
- UI Runner 使用 Xcode 的本地临时签名构建并通过 `codesign --verify --deep --strict`；测试未再触发 macOS“已损坏”拦截
- 模型 UI 测试会在多显示器环境下将测试窗口归位到主屏可见区域，并通过 Model 菜单选择 Kokoro，避免依赖持久化窗口坐标或侧边栏命中位置
- 所有 `--uitest-*` 启动模式使用独立内存数据库和临时 Application Support 根目录，不读取或修改用户的真实模型设置与文件
- 模型 UI 测试实际通过音色 Picker 从 `zf_001` 切换到 `zf_002`，验证选择成功、模型详情刷新后仍停留在 Kokoro，且不出现版本不匹配错误
- 真实 Kokoro Swift 冒烟测试使用本机缓存的官方模型包实际执行并通过
- 旧版本数据库中的 Kokoro 音色清单会在启动时与当前签名模型清单同步；过期音色会安全回退到 `zf_001`，随后可重新选择并持久化其他有效音色
- 覆盖 Swift Testing、XCTest、XCUITest
- 包含 EPUB 安全解析、SwiftData、队列/暂停/恢复、系统语音、XPC DTO、M4B、ZIP64、导出、安全、隐私、本地化、VoiceOver、键盘和外观测试
- 端到端 UI 测试实际执行 EPUB → 章节 → 队列 → M4B → ZIP，不使用预览书籍代替业务流程
- 端到端 UI 测试会在验证按钮标识、标签和可点击状态后按已确认坐标点击，避免 SwiftUI 最后一次数据刷新替换按钮造成 XCUI 过期元素；修复后该用例单独 1/1、整套 UI 8/8 通过

Xcode 输出中的 `DebuggerLLDB.DebuggerVersionStore.StoreError` 是 Xcode 读取调试器版本快照的环境诊断；测试结果包没有对应测试失败，应用控制台未出现此前的 `layoutSubtreeIfNeeded` HTML importer 问题。

## 真实 EPUB 验收

输入文件 SHA-256：

`409fe0568d197bd01e2e7984a173b62f0ec2d12b5cb281f7ee77099b648c697f`

验收结果：

- 标题：论中国与世界
- 作者：李光耀
- 语言：zh-CN
- 章节数：14
- 14 个章节全部生成并通过 M4B 回读校验
- ZIP 中包含 14 个 M4B、封面、`metadata.json` 和 `README.txt`
- 转换前后原 EPUB 哈希一致
- 测试期间峰值常驻内存：186,363,904 bytes（约 177.7 MiB）
- RecoveryCoordinator 的数据库提交前中断、partial/final 产物与显式继续场景均通过
- `unzip -t`：无错误
- Finder/Archive Utility 同路径的 `ditto -x -k`：成功

保留产物：

- `build/acceptance/李光耀论中国与世界-14章验收.zip`
- `build/acceptance/extracted/`
- `build/full-attachments/真实 EPUB 内存与完整性验收`对应的导出附件

### Kokoro 全书端到端

另以官方外置 Kokoro INT8 模型、默认音色 `zf_001` 对同一本真实 EPUB 完成生产路径验收。测试先生成试听，创建并锁定 `model ID + 1.1-int8 + zf_001`，启动后立即暂停，再销毁并重新创建 SwiftData 容器和原生运行时；重启阶段不创建下载器或网络推理 API，使用相同锁定版本离线继续至完成并导出 ZIP。

- 结果包：`build/Kokoro-RealEPUB-Acceptance.xcresult`，1 个测试通过、0 失败
- 墙钟时间：21,705.009 秒（约 6 小时 1 分 45 秒）
- 14/14 章、75,248/75,248 字完成；14 个 M4B 均可由 `afinfo` 回读
- 合计音频：15,124.825 秒（约 4 小时 12 分 5 秒）；合计 M4B：122,020,681 bytes
- 全流程墙钟/音频比约 1.435；该口径还包含模型试听、暂停、进程内持久化重启、M4B 封装和 ZIP 导出，不等同于纯推理 RTF
- ZIP：116 MiB，`unzip -t` 无错误，内部含 14 个 M4B
- 源文件转换前后 SHA-256 均为 `409fe0568d197bd01e2e7984a173b62f0ec2d12b5cb281f7ee77099b648c697f`
- 保留产物：`build/acceptance/李光耀论中国与世界-Kokoro-zf_001.zip`、`build/acceptance/kokoro-real-epub-completed.txt`、`build/acceptance/kokoro-real-epub-m4b-audit.txt`

## Apple 播放器验收

抽查文件：`0002-重要人物如何评价.m4b`

- `afinfo`：M4A/M4B 容器、AAC、单声道、44.1 kHz、3.0 秒，可读取 132 个音频包
- QuickTime Player：成功打开；AppleScript 返回文档时长 3.0 秒
- QuickTime Player：实际执行播放后，播放位置由 0 前进到 0.70981253 秒，再暂停
- Apple Books：成功接受该 M4B 打开请求并启动
- AVFoundation 自动化回读额外验证音频轨、时长、元数据、章节项和全文文本轨

当前既有端到端测试用 mock 音频较短，适合结构与兼容性验收；生产 App 可使用 Apple 系统语音或本机 Kokoro。

## Kokoro Intel 冒烟基准

在 x86_64 Mac 上，使用官方 `kokoro-int8-multi-lang-v1_1` 包和 App 内嵌的 sherpa-onnx/ONNX Runtime 动态库完成真实合成：输出 113,711 个采样、24 kHz、单声道，音频时长 4.738 秒；冷进程总耗时 12.16 秒。该数据包含模型加载与首次合成，后续需要把长章节、峰值内存、取消响应和 Apple Silicon 同口径结果补入本节。

Swift 集成测试也通过真实 `KokoroTTSRuntimeClient` 完成模型探测、103 个音色校验和音频生成；最新全量测试中该用例耗时 33.260 秒。测试负载与独立冷进程口径不同，不能直接用于产品性能对比。

2026-07-19 使用官方 HTTPS 地址重新下载完整模型并运行固定口径 CPU 基准，结果如下：

- 下载：147,031,220 bytes，44.492 秒，平均 3,304,648 bytes/s；SHA-256 为 `a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6`，与签名清单一致
- 生产 `ModelPackageManager` 真实下载安装：从同一签名清单 URL 下载 147,031,220 bytes，完成重定向白名单、大小与 SHA-256 校验、安全解包、原子安装、376 个数据文件的安装收据（含收据共 377 个文件）及离线运行时探测，耗时 65.209 秒；结果包为 `build/Kokoro-Official-Download-Acceptance.xcresult`
- 冷加载：2.671 秒
- 首段：墙钟 6.505 秒，音频 3.980 秒，RTF 1.635
- 三个连续长段：墙钟 207.901 秒，音频 127.605 秒，RTF 1.629；三个 WAV 均可由 `afinfo` 回读
- 常驻内存：加载前 2.4 MiB，加载后约 320.2 MiB，峰值约 515.8 MiB
- 原生回调取消：请求在 0.1 秒发出，生成调用于 3.212 秒返回；Swift 运行时端到端取消两次实测为 4.687 秒和 4.698 秒
- 强制 20 ms 超时：两次端到端实测为 6.794 秒和 6.818 秒，均返回 `runtime.timedOut` 并删除不完整 CAF

详细数据保存在 `build/acceptance/kokoro-download-benchmark.txt`、`build/acceptance/kokoro-intel-benchmark.txt` 和 `build/acceptance/kokoro-test-attachments/`。基准工具为 `Tools/Smoke/kokoro-benchmark.c`。

同日又用发布门禁脚本完整复跑一次 x86_64 主机验收，证据目录为 `build/acceptance/kokoro-x86_64-host-final/`：

- `environment.txt` 确认主机与原生基准可执行文件均为 `x86_64`，模型 SHA-256 与签名清单一致
- 冷加载 2.666 秒；首段墙钟 6.538 秒、音频 3.986 秒、RTF 1.640
- 三个连续长段墙钟 208.466 秒、音频 127.559 秒、RTF 1.634
- 加载后常驻内存约 319.6 MiB，峰值约 515.2 MiB；0.1 秒后请求取消，生成调用于 3.297 秒返回
- `Kokoro-Host-Smoke.xcresult` 中真实 Kokoro 测试 1/1 通过，耗时 32.485 秒
- `audio/` 中首段及三条听感样本均已生成；运行日志中的未知音素提示继续作为人工听感重点

模型会记录未知 token/音素并跳过，这是已知发音风险。基准还发现 Kokoro v1.1 会忽略 `max_num_sentences=2`；运行时配置已据此改为受支持的 `1`，长文本仍由产品层 `TextChunker` 在请求前切片。听感验收不得忽略未知音素警告。

默认第三方音色候选已固定为 `zf_001`（speaker ID 3）。界面中文试听样句固定为“你好，这是本地音色试听。”，避免 `〇` 的未知 token 和英文品牌名生成的 `U+025A` 未知音素；数字、日期、专名、中英混排和章节边界扩展样本位于 `build/acceptance/kokoro-benchmark-output/listening-1.wav`。人工听感签字完成前，OpenSpec 8.4 保持未完成。

为便于逐项听辨，另以外置安装模型生成 `build/acceptance/kokoro-listening-acceptance/` 下的 5 个 24 kHz 单声道 WAV：`01-numbers-money.wav`（8.988 秒）、`02-date-time.wav`（6.930 秒）、`03-proper-names.wav`（7.559 秒）、`04-mixed-language.wav`（8.332 秒）和 `05-chapter-boundary.wav`（7.212 秒）。输入保留 `3.5%`、`123.50元`、`2026年7月19日` 与 `9:30` 等原始写法，以覆盖模型文本规范化；生成日志出现未知音素 `U+025A` 跳过警告，专名和中英混排试听必须重点确认是否丢音或误读。

## Instruments 与主线程

保留轨迹：

- `build/AudiobookMaker-TimeProfiler.trace`
- `build/AudiobookMaker-Logging.trace`
- `build/AudiobookMaker-potential-hangs.xml`
- `build/AudiobookMaker-hang-risks.xml`
- `build/AudiobookMaker-Logging-signpost-intervals.xml`

结果：

- Time Profiler 的 potential-hangs 表为零行
- Time Profiler 的 hang-risks 表为零行
- EPUB Import signpost：33.07 ms，后台线程
- Book Conversion signpost：184.18 ms，后台 actor/Core Media 工作线程
- Book Export signpost：17.41 ms，后台线程
- Core Media 音频压缩与 QuickTime movie writer 均显示专用非主线程
- 导入和导出显式使用 utility 优先级的 detached task；封面降采样使用 utility detached task；XPC 使用异步 continuation，没有同步等待

## 可交付应用

最新通用 Release Archive：`build/AudiobookMaker-Kokoro-VoiceFix.xcarchive`

校验：

- `codesign --verify --deep --strict` 通过
- App Sandbox 开启
- User Selected File Read/Write entitlement 开启
- Network Client entitlement 开启，仅用于用户明确触发的模型下载
- App 主可执行文件、`libsherpa-onnx-c-api.dylib` 和 `libonnxruntime.1.24.4.dylib` 均包含 `x86_64` 与 `arm64` slice
- App bundle 扫描确认不包含 `.onnx`、`voices.bin` 或 Kokoro 模型权重
- 最新 App bundle 大小约 67 MiB；归档包含 Kokoro 音色清单迁移、模型详情选择保持和 UI 测试数据隔离修复
- x86_64 与 arm64 Release 分别完成构建；当前 Archive 为本机 ad-hoc 签名，尚未使用 Developer ID 公证

## 剩余验收与回滚

当前环境是 Intel Mac，无法代替 Apple Silicon 实机执行 Kokoro、测量同口径性能或验证实际 slice 选择；也没有 Developer ID 凭据进行公证。发布前还需完成 Apple Silicon 实机基准，以及数字、日期、专名、中英混排和章节边界的人工听感验收。可执行步骤和证据要求见 `docs/kokoro-release-gates.md`；Apple Silicon 实机可运行 `Tools/Smoke/run-kokoro-host-acceptance.sh` 一次生成原生基准和真实 Swift 运行时结果包。

回滚开关是把默认模型保持为 Apple 系统语音，并在发布清单中隐藏或禁用 Kokoro 入口；已创建任务仍保留锁定的 model ID、model version 和 voice ID，不会静默切换语音引擎。需要恢复这些任务时，应重新安装其锁定版本，或由用户明确新建 Apple 系统语音任务。
