# speech-swift 发布、用户帮助与回滚门禁

## 用户操作

在原生 Apple Silicon Mac 的“模型”页选择 CosyVoice3 或 Qwen3-TTS。详情页展示固定版本、下载大小、许可、预置音色和状态；点击“下载模型”后可观察逐文件进度或取消。校验与离线探测成功后可以试听、搜索音色并设为默认。暂停或停止时，MLX 推理可能先完成当前安全片段；该片段的晚到结果会丢弃，不会写入章节。

“需要原生 Apple Silicon”表示当前是 Intel、Rosetta、旧系统或 Metal 不可用。此时不要尝试手工复制模型；Apple 系统语音和 Kokoro 仍可使用。“模型已损坏”表示固定 snapshot 缺文件或收据不匹配，应点击“重新下载”。安装需要约模型大小两倍加至少 512 MiB 安全余量。

## 构建初始化与归档

1. 使用完整 Xcode，运行 `xcodebuild -runFirstLaunch`，并用 `xcodebuild -downloadComponent MetalToolchain` 安装 Metal 工具链。
2. 用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -resolvePackageDependencies -project AudiobookMaker.xcodeproj -scheme AudiobookMaker` 复验 `Package.resolved`。
3. 以 Release/arm64 构建 `CosyVoiceTTS` 与 `Qwen3TTS`；项目构建必须运行 `Build MLX Metal Library`，缺失或空的 `Contents/Resources/MLX/mlx.metallib` 直接失败。
4. 构建最终 universal Release archive。扫描 App bundle，禁止 CosyVoice3/Qwen3-TTS 权重、tokenizer/codec 缓存、参考声音和用户模型；必须存在非空 MLX metallib。
5. 使用 Developer ID Application 签名并验证 hardened runtime；提交公证、staple，随后通过 `codesign --verify --deep --strict`、`spctl --assess --type execute` 与 `stapler validate`。

### 2026-07-22 本机门禁记录

- 完整 Xcode 26.6（17F113）首次启动步骤已完成；使用显式 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 构建。
- Metal Toolchain 已安装，`metal`、`metallib` 和项目的 MLX metallib 构建门禁可用。
- Apple Development 身份 `H6RZPFNTDZ`（Team `5Q85C9M9LA`）可用于本机开发签名；签名 Debug App 已通过 `codesign --verify --deep --strict`，并启用 hardened runtime。
- 系统开发目录已切换到 `/Applications/Xcode.app/Contents/Developer`，Developer Tools 模式已启用；`xcode-select -p`、`DevToolsSecurity -status` 与 `xcodebuild -version` 已分别确认完整 Xcode 路径、enabled 和 Xcode 26.6（17F113）。UI 测试的管理员初始化阻塞已解除；原全书性能进程已按缩短后的验收范围停止，测试可以运行。
- 钥匙串没有 `Developer ID Application` 身份，因此无法在本机完成 Developer ID 分发签名、公证、staple 或 Gatekeeper 分发验收。
- speech-swift 0.0.23 的 `CosyVoiceTTS/CamPlusPlusSpeaker.swift` 在 x86_64 编译时使用 macOS 不可用的 `Float16`，曾导致 universal archive 失败；同一依赖的 arm64 Release 构建通过。现已将固定 revision 的四个必需 target 作为可审计 vendor 子集，并只为不对用户开放的 CAM++ 克隆组件增加 x86_64 不可用 stub，arm64 源码保持上游实现。7.8 仍需以新的干净 universal archive 实测后才能解除该构建阻塞，不能以静态检查或既有 arm64 archive冒充通过。
- 新的干净 universal Release build 已使用本地 vendor 包实际完成，主二进制经 `lipo` 确认为 `x86_64 arm64`，102 MiB MLX metallib 存在，bundle 扫描未发现模型权重；Development 签名与 hardened runtime 已通过 `codesign --verify --deep --strict`。这解除原 x86_64 编译阻塞，但不替代最终 archive、Developer ID、公证与 Gatekeeper 门禁。
- Rosetta 2 已由用户接受许可并安装；`pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto` 返回版本 `1.0.0.0.1782352074`，`arch -x86_64 /usr/bin/uname -m` 返回 `x86_64`。同一 universal Release App 的 x86_64 slice 在 Rosetta 下执行 `--speech-swift-acceptance`，3.7 秒内以退出码 1 和稳定“此模型需要原生 Apple Silicon、受支持的 macOS 和 Metal”错误结束，且在创建证据目录、模型校验、下载或 runtime session 之前被平台门禁拒绝。最终 Developer ID archive 又通过 `--kokoro-compatibility-acceptance` 复验：`architecture=x86_64`、`is_rosetta_translated=true`、`speech_swift_rejected=true`，同时已安装 Kokoro 1.1-int8 使用 `af_maple` 生成 24 kHz 单声道 6.2235 秒 CAF；指标/CAF SHA-256 分别为 `1ead233c8f00c7826ff3a21cd55d316fdff64d6f626818c4c5bb6b4641166f3b` 与 `ce6867528053daf71993488c3501083718b1c809f042ff88d6d9eb202b25dbf4`。7.6 仅剩 Intel Mac 实机结果。
- Developer ID Application 身份 `A14944A25D684C4D508CC13E53AED10D315D0875` 与公证钥匙串 profile `AudiobookMaker-notary` 已验证可用。最终干净 archive `AudiobookMaker-speech-swift-final-20260722.xcarchive` 已成功构建，主程序为 `x86_64 arm64`，签名 authority 为 `Developer ID Application: Shuo Jia (5Q85C9M9LA)`，含 hardened runtime、安全时间戳、沙箱/网络/用户选择文件 entitlement 和 102 MiB metallib，bundle 模型/音频扫描计数为 0。公证 ZIP SHA-256 为 `cc3a3b4a4c4cf0b81522cd036b381c03ec2e315ac6570f3970df9ebc9e5fd1c9`；Apple S3 上传因网络 deadline 多次中断，关闭 acceleration 后取得 submission `e4645504-fbf0-420c-8b55-b9702b77d621`，但最终分片仍超时，尚不能声明公证完成。
- UI runner 已成功构建和 Development 签名，但系统在启用 automation mode 时要求设备所有者认证，两次均因未完成系统认证在 60 秒后超时；UI 用例尚未实际执行，6.7 保持未完成。
- 真实 CosyVoice3 snapshot 下载确认 Hugging Face 大文件当前重定向到精确主机 `us.aws.cdn.hf.co`。该主机已加入 v2 签名清单并轮换清单公钥/两份模型签名；仍拒绝 HTTP、后缀伪造和未签名主机。CosyVoice3 的 1,121,605,600 字节 snapshot 随后完成逐文件校验、原子安装与离线加载。

## 实机验收

在原生 Apple Silicon 上分别记录两个模型的实际下载字节、冷/热加载、首段延迟、RTF、峰值内存、磁盘占用、长章节稳定性、取消边界与切换后内存释放。用 `docs/李光耀观天下.epub` 完成固定试听、暂停/继续、断网重启、长章节、M4B 导出和人工听感；听辨数字、日期、专名、中英混排及章节边界。

数值发布门禁在 `docs/speech-swift-model-selection.md` 的“预先冻结的性能与稳定性阈值”中定义，必须直接由验收 runner 的 `metrics.json`、最终 M4B 和进程日志复验。不得在看到某个模型最终结果后为其单独放宽阈值；若固定变体失败，应阻止该变体发布或另开受审计的变体变更。

人工听感使用 `docs/speech-swift-listening-acceptance.md` 的固定输入、默认 voice、逐项判定标准和签字栏；两组真实 CAF 未全部听完并签字前，7.7 保持未完成。

### 2026-07-22 CosyVoice3 已保留证据

- 固定 snapshot `b52fc1c3bf5f3b947d40c250639e5ebe347ece11`（1,121,605,600 字节）已完成签名清单约束的下载、逐文件大小/SHA-256 校验、原子安装和本地离线冷加载。
- 已生成数字、专名、中英混排、章节边界和固定试听 5 个真实 24 kHz CAF，以及 450 字长段落和卸载后离线重载样本；这些产物只用于自动结构/性能与后续人工听感，自动生成不代表听感门禁通过。
- 真实 EPUB 解析为 41 章、150,101 字。任务已在 477 字处完成协作式暂停 checkpoint；随后终止进程并重新启动，恢复时仍锁定同一 model ID、snapshot、`default` voice 且未重新下载，继续自首个未完成 checkpoint 转换。
- 用户确认不需要全书验收后，launchd 主任务与 watcher 已安全卸载；停止时无崩溃地完成 11 章、36,200 字。该记录作为超过最低子集规模的稳定性补充证据保留，但不冒充最终子集 M4B/指标。
- 后续 runner 固定选择至少 500 字的前段、中段、后段 3 个正文章节完成转换与 M4B，并另外对最长章节执行 450 字压力片段；CosyVoice3 与 Qwen3-TTS 都采用同一选择规则。
- CosyVoice3 固定子集已完成：章节索引 `0/19/38`、12,607 字、M4B 2,450.92 秒/19,744,896 字节；冷加载 2.049 秒、首段 3.101 秒、450 字压力片段 29.019 秒、综合 RTF 0.332、子集 wall/audio 比 0.342、峰值 RSS 2,563,850,240 字节、卸载后 RSS 1,170,718,720 字节、模型磁盘 1,121,607,031 字节。`release_gate_passed` 为 `true` 且无失败项；最终 M4B 经 `afinfo` 独立确认为单声道 AAC 44.1 kHz、时长 2,450.92 秒，SHA-256 为 `9996dab1ca3262f91ba54dbdf9d56c3a873f1d8e60fcda26552cc1a2c68f220d`。人工听感仍单独待验。

### 2026-07-22 Qwen3-TTS 已保留证据

- 固定 snapshot `3affbf656d9d6aa9255ec0b31cc90055605170bc+tokenizer-7dd38ad4` 已完成签名清单约束的下载、逐文件校验、原子安装、本地加载和离线重启。
- 固定子集已完成：章节索引 `0/19/38`、12,607 字、M4B 2,577.52 秒/20,676,176 字节；冷加载 0.590 秒、首段 2.675 秒、450 字压力片段 44.458 秒、综合 RTF 0.439、子集 wall/audio 比 1.247、峰值 RSS 7,444,480,000 字节、卸载后 RSS 162,299,904 字节、模型磁盘 2,498,420,581 字节。`release_gate_passed` 为 `true` 且无失败项；最终 M4B 经 `afinfo` 独立确认为单声道 AAC 44.1 kHz、时长 2,577.52 秒，SHA-256 为 `58ccd4b2752f6e8f2b513be98db5e54fcd3123b6c4bf07122e9ac7d3664554c5`。指标文件 SHA-256 为 `471cfe0b5c470e31886b8f9a98b5d3c025aa918ea50e4bbe96982368dfadd2d7`。
- 外部 launchd watcher 在首次完成后失效，导致同一已完成验收被重复启动；发现后已按精确标签卸载主任务和 watcher，确认无遗留验收进程。重复启动没有删除或替换模型、书籍源文件和首个完整 M4B，但日志包含后续重复运行记录；以上冻结指标取自最后一份仍通过全部阈值、且与独立 `afinfo` 结果一致的完整 `metrics.json`。

在 Intel Mac 与 `arch -x86_64` Rosetta 进程确认两个 speech-swift 模型没有下载/加载入口并返回稳定不兼容错误，同时完成一次 Kokoro 试听或转换。发布证据必须包含真实硬件结果，不能用注入式单元测试替代 Intel 实机。

## 回滚

发布开关可从统一模型目录隐藏 CosyVoice3/Qwen3-TTS，并把新任务默认值保持或恢复为 Apple 系统语音。不得删除仍被未完成任务锁定的 model ID + version；不得把旧 CosyVoice/MLX 占位 ID 自动迁移到新稳定 ID，也不得静默回退到其他引擎。恢复旧任务时重新安装其锁定 snapshot，或由用户明确新建使用 Apple 系统语音/Kokoro 的任务。
