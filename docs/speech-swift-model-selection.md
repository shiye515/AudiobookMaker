# speech-swift 首发模型选型

## 固定运行时

- speech-swift tag：`v0.0.23`
- revision：`c1aa219bc2284239ff6917d675a3e1978c840260`
- 最低运行环境：Swift 6、macOS 15、原生 Apple Silicon、Metal
- 本机 spike：macOS 26.5.2 arm64；`CosyVoiceTTS` 与 `Qwen3TTS` 均以 Release target 构建成功
- MLX Metal library：使用 Xcode 26.6 Metal Toolchain 17F109 从固定 MLX 0.31.6 源码生成，spike SHA-256 为 `0d29caeba83e59e98a04cf822fdd684f5ef4b93210847a385124faf4d9353ab3`

产品工程通过 `Vendor/speech-swift` 集成固定 revision 的 `AudioCommon`、`MLXCommon`、`CosyVoiceTTS` 与 `Qwen3TTS` 源码子集；`UPSTREAM.md` 记录上游 revision 与各子树对象 ID，唯一源码补丁保存在 `PATCHES/0001-campp-intel-compile-stub.patch`。vendor manifest 将 `mlx-swift` 固定为 `0.31.6`、`swift-transformers` 固定为 `1.3.3`，不再引入上游跟踪 `main` 的 `mlx-swift-lm`。产品工程仍必须提交由 Xcode 重新解析生成的 `Package.resolved`，不得手工编辑或无约束升级传递依赖。

## Qwen3-TTS

首发选择：`aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16`

| 候选 | Snapshot 大小 | 音色 | 质量/资源结论 |
| --- | ---: | --- | --- |
| 0.6B CustomVoice bf16 | 1,816,120,666 B | 9 个预置 speaker | 首发；Apache-2.0，支持 Kokoro 式音色选择，bf16 避免已知量化音质损失 |
| 1.7B Base 8-bit | 2,421,858,094 B | 无预置 speaker | 上游英文 round-trip WER 更低，但下载/内存更高且不满足多音色交互 |
| CoreML FP16 | 1,733,129,292 B | Base/default | 体积较小且无需 MLX，但没有预置 speaker；保留为后续低内存后端 |

Qwen3-TTS 还依赖 `Qwen/Qwen3-TTS-Tokenizer-12Hz`（682,300,739 B，Apache-2.0）。CustomVoice 预置 speaker 为 `serena`、`vivian`、`uncle_fu`、`ryan`、`aiden`、`ono_anna`、`sohee`、`eric`、`dylan`；首发默认音色为 `vivian`。上游公开基准显示 1.7B 8-bit 的英文 round-trip WER 为 3.66%、RTF 0.85，0.6B 8-bit 为 9.74%、RTF 0.76；本项目仍要求用中文书籍完成独立听感、内存和 RTF 门禁。

## CosyVoice3

首发选择：`aufklarer/CosyVoice3-0.5B-MLX-8bit-full`

| 候选 | Snapshot 大小 | 量化 | 结论 |
| --- | ---: | --- | --- |
| 8-bit-full | 1,121,605,600 B | LLM 与 DiT 均 int8；HiFi-GAN 保持 float | 首发；Apache-2.0，上游标记为最佳质量/体积折中；固定 snapshot 已完成真实下载与逐文件校验 |
| 8-bit | 1,907,089,467 B | LLM int8，DiT 保持高精度 | 体积更大；若中文听感发现 8-bit-full DiT 退化则回退 |
| bf16 | 2,252,995,168 B | LLM 与 DiT bf16 | 参考质量，但下载和峰值内存最大 |

CosyVoice3 无需参考音频即可使用内置默认说话方式，因此首版将其暴露为稳定 voice ID `default`。零样本克隆、录音、参考音频与风格指令不在本次范围内。首发固定 seed，以减少有声书跨片段的音色和韵律漂移。

## 发布结论

上述选择是实现和真实模型验收的固定候选。若 `docs/李光耀观天下.epub` 的中文听感、峰值内存、长章节稳定性或取消门禁失败，只允许切换到表内已审计变体并更新签名 manifest；不得静默放宽质量或资源门禁。

### 预先冻结的性能与稳定性阈值

以下阈值在两个模型的最终代表性章节子集指标生成前冻结，CosyVoice3 与 Qwen3-TTS 分别判定；任一硬门禁失败即阻止发布对应变体：

- 冷加载不超过 120 秒；已加载 session 的热能力握手和首个固定试听片段分别不超过 30 秒。
- 450 字真实长段落必须在 180 秒内完成，且固定试听加长段落的实测 RTF 不超过 1.5。
- 固定的前段/中段/后段 3 个正文章节必须无崩溃、watchdog、章节遗漏或 checkpoint 损坏地完成；子集墙钟时间与最终子集 M4B 音频时长之比不超过 1.5。最长章节另取 450 字独立验证安全切片，不要求合成整本 EPUB。
- 峰值 RSS 不超过 `min(12 GiB, 物理内存的 75%)`。
- 卸载后的 RSS 不超过 `max(加载前 RSS + 2 GiB, 峰值 RSS 的 70%)`；切换模型后还必须确认前一 session 已释放，不能只依赖进程级 RSS。
- 模型目录占用不超过签名 manifest 声明安装字节数加 `max(16 MiB, 5%)`，App bundle 中不得出现模型权重或缓存。

自动数值只能证明资源与结构门禁；默认 voice、数字/日期、专名、中英混排和章节边界仍需按听感清单人工签字。
