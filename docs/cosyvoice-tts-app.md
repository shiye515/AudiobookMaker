# CosyVoice TTS macOS 原生应用 — 技术文档

> 版本: v0.2（已更新技术路线：Soniqo speech-swift 原生集成）
> 日期: 2026-09-13
> 目标: 用 Swift 构建一个 macOS 原生应用，通过 CosyVoice3 将文本合成为语音。

---

## 1. 项目概述

### 1.1 MVP 界面（用户已确认的范围）

一个"超级简单"的窗口，包含四个控件：

```
+----------------------------------------------------------+
|  CosyVoice TTS                                    [_][O][X]|
+----------------------------------------------------------+
|  [ 初始化模型 ]      状态: ● 未下载 / 下载中 / 加载中 / 就绪   |
|                                                          |
|  音色: [ 内置-男声示例               v ]                   |
|                                                          |
|  +------------------------------------------------------+|
|  |  (文本输入框, 多行)                                    ||
|  |                                                      ||
|  +------------------------------------------------------+|
|                                                          |
|  [ 合成并播放 ]   [ 停止 ]                                 |
+----------------------------------------------------------+
```

### 1.2 技术路线（v0.2 已定）

| | ~~路线 A: 百炼云 API~~（备选） | **路线: Soniqo speech-swift（本方案）** |
|---|---|---|
| 推理位置 | 阿里云 | 本机 Apple Silicon，纯 Swift/MLX |
| 模型 | cosyvoice-v3-flash | Fun-CosyVoice3-0.5B（MLX 量化权重，自动下载） |
| Swift 端接入 | URLSessionWebSocketTask 实现协议 | SPM 依赖 `CosyVoiceTTS` |
| 音色 | 80+ 官方预置音色 ID | 零样本克隆，参考音频库 |
| 离线 | 否 | 是 |
| App Store | 可 | 理论可（纯 Swift/MLX，可沙盒化） |

> 历史背景：v0.1 曾评估"Swift 壳 + 内嵌 Python"（B1）与"纯 Swift/MLX 自行移植"（B2）两条路，
> 代价分别为依赖地狱/+5GB 体积/不可沙盒 与 数周移植工作量。**Soniqo speech-swift 直接消除了这两类代价**，
> 它把 MLX 推理栈做成了开源 SPM 包。原代价分析保留在附录 C 作为背景。

---

## 2. 技术选型

### 2.1 推理框架: [soniqo/speech-swift](https://github.com/soniqo/speech-swift)

- **是什么**: 开源（Apache 2.0）的 Apple Silicon 端侧语音 AI 工具包，MLX + CoreML 驱动，覆盖 TTS/ASR/VAD/说话人分离。1.2k star、活跃迭代中。
- **CosyVoice 支持**: SPM 产品 `CosyVoiceTTS`，基于 Fun-CosyVoice3-0.5B，三阶段流水线（Qwen2.5-0.5B LLM → DiT 流匹配 → HiFi-GAN），24 kHz 输出，支持 9 种语言、流式合成、声音克隆、多说话人、情感标签。
- **性能（官方标称，M2 Max）**: RTF ≈ 0.5（快于实时）；LLM ~13 ms/token、DiT 370–520 ms、HiFi-GAN 50–170 ms。CAM++ 说话人编码器走 CoreML/Neural Engine（FP16）。

### 2.2 SPM 集成

```swift
// Package.swift 或 Xcode → Add Package Dependency
.package(url: "https://github.com/soniqo/speech-swift", branch: "main")
.product(name: "CosyVoiceTTS", package: "speech-swift")
```

> **锁定 commit**：该仓库目前**没有任何正式 release/tag**（0.0.x 阶段，官方建议用 main 分支）。
> 项目必须锁定具体 commit hash，升级前在分支上验证。

### 2.3 模型权重

| 变体 | 大小 | 用途 |
|---|---|---|
| 4bit（默认） | ~1.2 GB | MVP 首选，体积最小 |
| 8bit / 8bit-full | ~1.4 / ~1.6 GB | 音质与体积折中 |
| bf16 | ~2.1 GB | 长文本或克隆场景建议（官方推荐） |

首次使用自动下载，落盘到应用支持目录；CAM++ 编码器约 14 MB 随用随下。

---

## 3. 剩余代价与风险（本路线仍需正视的）

之前最大的两类代价（内嵌 Python、自行移植 MLX）已被框架消除，但以下仍在：

1. **无 tag/release，API 未稳定**：`import CosyVoiceTTS` 的接口可能在任意一次 main 分支更新中变动。对策：锁定 commit hash + 把对框架的调用收敛到自有 `TTSEngine` 协议后面（见 4.2），升级时只改适配层。
2. **性能数据是官方标称**：RTF 0.5 未经本项目实测。M0 spike 第一件事就是实测自己机器的 RTF 和首包延迟。
3. **音色 = 参考音频，不是预置音色 ID**：本地模型是零样本克隆，"音色选择框"必须设计成参考音频库（见 3.2）。百炼那 80 个预置音色只在云 API 路线可用。
4. **克隆合规**：声音克隆涉及伦理与法律，只克隆有权使用的声音；App 内需提示。
5. **首次初始化慢**：下载 1.2–2.1 GB 权重 + 每次启动加载模型，"初始化模型"按钮是带进度的长任务。
6. **框架成熟度**：0.0.x 阶段，遇到 bug 可能需要提 issue 或临时绕行，没有 SLA。

## 3.2 音色设计: 参考音频库

```
音色选择框（下拉）
└── 内置音色包: 10 个有声书音色（龙妙/龙三叔/…，随 App 打包参考音频，
    清单见 docs/sample/audiobook_voices.json）
```

> 范围已确认（2026-09-13）：**不支持用户导入自定义音色**，音色库固定为内置 10 个。
> 每个音色 = 一条记录 `{name, referenceAudioPath, referenceTranscript}`，合成时通过
> 零样本克隆传入（CAM++ 提取 192 维嵌入条件化 DiT）。

---

## 4. 架构与实现

### 4.1 整体架构（比 v0.1 大幅简化：无 Python、无子进程）

```
+------------------------------------------------------------+
|                      CosyVoiceApp.app                       |
|                                                            |
|   SwiftUI 界面                                              |
|   [初始化模型] [状态] [音色下拉] [文本框] [合成并播放] [停止]    |
+-----------------------------+------------------------------+
                              | 直接函数调用 (async/await)
+-----------------------------v------------------------------+
|   Core 层 (Swift)                                          |
|   ModelStateManager: 状态机 (4.3)                           |
|   VoiceLibrary: 参考音频库 (3.2)                            |
|   AudioPlayer: AVAudioPlayer / AVAudioEngine               |
+-----------------------------+------------------------------+
                              | SPM: CosyVoiceTTS
+-----------------------------v------------------------------+
|   soniqo/speech-swift                                      |
|   MLX 推理: LLM + DiT 流匹配 + HiFi-GAN                     |
|   CoreML: CAM++ 说话人编码器                                 |
|   权重: Fun-CosyVoice3-0.5B (MLX 变体, 自动下载)             |
+------------------------------------------------------------+
```

### 4.2 引擎隔离层

框架调用收敛在自有协议后面，未来可加云 API 引擎而不动 UI：

```swift
protocol TTSEngine {
    var state: EngineState { get }                       // 未下载/下载中/加载中/就绪/出错
    func initialize(progress: @escaping (Double) -> Void) async throws
    func synthesize(_ text: String, voice: VoiceProfile) async throws -> AsyncStream<AudioChunk>
}
// 实现: SoniqoCosyVoiceEngine (MVP)、DashScopeEngine (可选后续)
```

### 4.3 状态机（"初始化模型"按钮驱动）

```
   点击初始化 +----------+
  +---------->+  未下载   |
  |           +----+-----+
  |                | 首次: 下载权重 1.2~2.1 GB (显示进度)
  |                v
  |           +----------+
  |  加载失败  |  下载中   |
  +---------->+----+-----+
  |                | 加载模型到内存
  |                v
  |           +----------+
  |           | 加载中    |   <-- 预期数十秒, spinner
  |           +----+-----+
  |                | 就绪
  |                v
  |           +----------+     合成中 (RTF~0.5, 禁用重复点击)
  +-----------+   就绪    |---------------------+
              +----+-----+     播放完毕/停止    |
                   | 出错(显示错误, 可重试)      |
                   v                          |
              +----------+                    |
              |   出错    |--------------------+
              +----------+
```

### 4.4 界面 → 组件映射

| 界面元素 | 实现 |
|---|---|
| 初始化模型按钮 | 驱动 4.3 状态机；就绪后变为"重新加载"（切权重变体时用） |
| 模型状态 | 状态机当前态 + 权重变体名 |
| 文本输入框 | `TextEditor` |
| 音色选择框 | 3.2 参考音频库（内置 + 用户导入） |
| 合成并播放 | `synthesize()` 的 `AsyncStream<AudioChunk>` → 流式喂 `AVAudioEngine`（或先攒整段用 `AVAudioPlayer`，MVP 可先整段） |

### 4.5 项目结构

```
CosyVoiceApp/
├── App/                        # SwiftUI 入口 + ContentView
├── Core/
│   ├── TTSEngine.swift             # 4.2 协议
│   ├── SoniqoCosyVoiceEngine.swift # 对 CosyVoiceTTS 的适配层(唯一接触框架的地方)
│   ├── ModelStateManager.swift     # 状态机
│   └── VoiceLibrary.swift          # 参考音频库
├── Playback/
│   └── AudioPlayer.swift
├── Resources/
│   └── bundled_voices/         # 内置参考音频
└── Package.swift / Project     # 依赖: speech-swift (锁定 commit)
```

---

## 5. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| **M0 (spike, 半天)** | 新建最小 SPM 项目，引入 `CosyVoiceTTS`，命令行式合成一段 WAV；实测本机 RTF、首包延迟、内存 | 能出声；拿到本机性能基线，确认值得继续 |
| M1 (MVP, 2-4 天) | 四控件 UI + 状态机 + 引擎适配层打通，合成→播放闭环 | 界面上点"初始化"到"合成并播放"全程可用 |
| M2 (体验, 2-3 天) | 音色库（内置 10 个，懒加载档案）、下载/加载进度、错误恢复、流式播放、WAV 导出 | 换音色重合成正常；中途停止不崩溃 |
| M3 (打磨, 可选) | 权重变体切换（4bit/bf16）、情感标签 UI、多说话人对话 | 变体切换后状态机正确流转 |
| M4 (可选) | `DashScopeEngine` 接入百炼云 API（协议细节见附录 A），同一 UI 双引擎切换 | 切引擎不改 UI 代码 |

---

## 6. 附录 A: 备选对照 — 百炼云 API（cosyvoice-v3-flash）

若做 M4 或本地路线不可行时启用，以下是已调研好的接入细节。

### 6.1 协议

- **端点**: `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`
- **鉴权**: 请求头 `Authorization: Bearer <API_KEY>`（百炼控制台获取），可选 `X-DashScope-WorkSpace`
- **事件流**: 客户端发 `run-task`（携带 model/voice/text 等 payload）→ 服务端回 `task-started` → 流式回 `result-generated`（音频分片，base64）→ `task-finished`；失败回 `task-failed`
- DashScope 官方 SDK 只有 Java/Python，Swift 用 `URLSessionWebSocketTask` 直接实现协议即可（约 200-300 行）

### 6.2 音色清单（cosyvoice-v3-flash，按场景分组）

| 场景 | voice ID |
|---|---|
| 社交陪伴标杆 | `longanyang`, `longanhuan_v3`, `longanhuan`, `longhuhu_v3` |
| 童声 | `longpaopao_v3`, `longjielidou_v3`, `longxian_v3`, `longling_v3`, `longshanshan_v3`, `longniuniu_v3` |
| 方言 | `longjiaxin_v3`, `longjiayi_v3`, `longanyue_v3`, `longlaotie_v3`, `longshange_v3`, `longanmin_v3` |
| 出海营销（多语种） | `loongkyong_v3`, `loongriko_v3`, `loongtomoka_v3`, `loongabby_v3`, `loongandy_v3`, `loongannie_v3`, `loongava_v3`, `loongbeth_v3`, `loongbetty_v3`, `loongcally_v3`, `loongcindy_v3`, `loongdavid_v3`, `loongdonna_v3`, `loongemily_v3`, `loongeric_v3`, `loongluna_v3`, `loongluca_v3`, `loongtomoya_v3`, `loongyuuna_v3`, `loongyuuma_v3`, `loongjihun_v3`, `loongindah_v3` |
| 诗词朗诵 | `longfei_v3` |
| 电话销售 | `longyingxiao_v3` |
| 客服 | `longyingxun_v3`, `longyingjing_v3`, `longyingling_v3`, `longyingtao_v3` |
| 语音助手 | `longxiaochun_v3`, `longxiaoxia_v3`, `longyumi_v3`, `longanyun_v3`, `longanwen_v3`, `longanli_v3`, `longanlang_v3`, `longyingmu_v3` |
| 社交陪伴 | `longantai_v3`, `longhua_v3`, `longcheng_v3`, `longze_v3`, `longzhe_v3`, `longyan_v3`, `longxing_v3`, `longtian_v3`, `longwan_v3`, `longqiang_v3`, `longfeifei_v3`, `longhao_v3`, `longanrou_v3`, `longhan_v3`, `longanzhi_v3`, `longanling_v3`, `longanya_v3`, `longanqin_v3` |
| 有声书 | `longmiao_v3`, `longsanshu_v3`, `longyuan_v3`, `longyue_v3`, `longxiu_v3`, `longnan_v3`, `longwanjun_v3`, `longyichen_v3`, `longlaobo_v3`, `longlaoyi_v3` |
| 短视频 | `longjiqi_v3`, `longhouge_v3`, `longdaiyu_v3` |
| 直播带货 | `longanran_v3`, `longanxuan_v3` |
| 新闻播报 | `longshuo_v3`, `longshu_v3`, `loongbella_v3` |

cosyvoice-v3-plus 仅支持 `longanyang`、`longanhuan`。模型与音色不可混用。

支持 Instruct 的音色（如 `longanyang`）可附加 `instruction` 参数，格式严格为 `"你说话的情感是happy。"`（必须以句号结尾；情感限定 neutral/fearful/angry/sad/surprised/happy/disgusted）。

---

## 7. 附录 B: 参考资料与来源

- [soniqo/speech-swift (GitHub)](https://github.com/soniqo/speech-swift) — 本项目推理框架，SPM 产品 `CosyVoiceTTS`
- [Soniqo CosyVoice 指南](https://soniqo.audio/zh/guides/cosyvoice) — CLI 用法、量化变体、克隆与情感标签示例
- [Soniqo 官网](https://soniqo.audio/zh/) — 产品定位与平台矩阵
- [CosyVoice 官方仓库 (FunAudioLLM/CosyVoice)](https://github.com/FunAudioLLM/CosyVoice) — 模型出处（Fun-CosyVoice3-0.5B，Apache 2.0）
- [CosyVoice3-0.5B-MLX-8bit-full (HuggingFace)](https://huggingface.co/aufklarer/CosyVoice3-0.5B-MLX-8bit-full) — Soniqo 使用的量化权重出处
- [CosyVoice3 Apple Silicon 优化实测 (drmhse)](https://www.drmhse.com/posts/running-funaudio-on-mac-mlx-pytorch/) — 原始 PyTorch 性能基线（RTF 1.65）与 MLX 混合优化方法论
- [CosyVoice WebSocket API 参考（阿里云）](https://help.aliyun.com/zh/model-studio/cosyvoice-websocket-api)
- [实时语音合成用户指南（阿里云百炼）](https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide)
- [CosyVoice 音色列表（阿里云百炼）](https://docs.bailian.console.aliyun.com/zh/model-studio/cosyvoice-voice-list)
- [ModelScope CosyVoice 模型搜索](https://www.modelscope.cn/models?name=CosyVoice&page=1&tabKey=task&tasks=hotTask:text-to-speech&type=tasks)

---

## 附录 C: 历史参考 — v0.1 评估过的本地路线代价

> v0.2 采用 speech-swift 后，以下路线不再使用，留作背景。

- **B1（Swift 壳 + 内嵌 Python 子进程）**：App 体积 +3~6 GB；沙盒不兼容（不可上架 App Store）；Python 依赖锁版本陷阱（如 mlx-lm 需 `--no-deps` 安装否则破坏 torch 栈）；PyTorch MPS 内存泄漏（实测进程 38.87 GB、swap 40.9 GB，唯一回收方式杀进程）；需自研内存预算守护（热基线 +2 GB，25-60 段回收，用 `phys_footprint` 监控而非 RSS）。
- **B2（自行 MLX-Swift 移植）**：仅 LLM 阶段参考实现约 320 行；Flow DiT + Vocoder 需自写并过质量门（log-spectral L1，NFE 6→3 时 L1 达 0.97 即实质劣化）；数周工程量。
- **原始 PyTorch 性能基线（M2 Max）**：RTF 1.65（LLM 0.71 / Flow 0.43 / Vocoder 0.14），"流式"退化为整段合成；MLX 混合优化后最好 RTF 0.757。fp16 flow decoder 在 MPS 崩溃、bfloat16 更慢且劣化、批量解码破坏可复现性等坑详见 drmhse 文章。
