# Apple Silicon 性能基准与发布门禁

## 固定环境

首个基线固定为以下环境；环境不一致时不得覆盖基线：

- 设备：Mac16,11，24 GiB 统一内存
- 系统：macOS 26.5.2，原生 arm64
- Xcode：26.6（17F113）
- 配置：Release、`ARCHS=arm64`
- 语料：`docs/李光耀观天下.epub`，SHA-256 `094d50f344d27e4184ffb6b50ea0e7b9465150840a1a5853c3d8e5c1929c4cc0`
- 模型：清单固定的 CosyVoice3 与 Qwen3-TTS revision，使用各自默认 voice
- 冷启动：新建 runtime actor，且进程中没有已加载的模型 session
- 热启动：同一已验证 session 上的第二次 capabilities 握手

历史 Universal 2 归档 App bundle 为 220,315,648 字节；当前 arm64 Release build 为
178,712,576 字节。2026-07-22 的模型指标保存在
`docs/apple-silicon-performance-baseline.json`。历史指标没有记录热加载值，因此该基线状态为
`historical-pre-change-baseline-incomplete`，比较脚本会失败关闭，直到维护者在上述固定环境重新采集并批准完整基线。

## 采集入口

先生成 arm64 Release archive，再分别运行两个模型：

```bash
Tools/archive-apple-silicon.sh

SPEECH_SWIFT_ACCEPTANCE_MODEL='soniqo.speech-swift/cosyvoice3-0.5b-mlx-8bit-full' \
AUDIOBOOKMAKER_WORKSPACE="$PWD" \
build/AudiobookMaker-AppleSilicon.xcarchive/Products/Applications/AudiobookMaker.app/Contents/MacOS/AudiobookMaker \
  --speech-swift-acceptance

SPEECH_SWIFT_ACCEPTANCE_MODEL='soniqo.speech-swift/qwen3-tts-12hz-0.6b-customvoice-mlx-bf16' \
AUDIOBOOKMAKER_WORKSPACE="$PWD" \
build/AudiobookMaker-AppleSilicon.xcarchive/Products/Applications/AudiobookMaker.app/Contents/MacOS/AudiobookMaker \
  --speech-swift-acceptance
```

每个模型生成 `build/acceptance/speech-swift/runtime/<model>/metrics.json`。结果格式版本为 2，包含设备、内存、系统、架构、构建配置、App 体积、模型/runtime revision、语料哈希、冷热启动定义、加载与首音频时间、RTF、峰值/卸载后 RSS、失败率、模型磁盘和 M4B 指标。

候选结果必须通过：

```bash
Tools/compare-performance-baseline.py \
  build/acceptance/speech-swift/runtime/<model>/metrics.json \
  docs/apple-silicon-performance-baseline.json
```

比较器要求设备、内存、架构、模型版本和语料完全可比，并按基线中的门限检查 App 体积、冷热加载、首音频、RTF、峰值内存和失败率。缺少样本或缺少基线字段会直接失败。

## 2026-07-23 profile 结论

对现有真实模型指标、signpost 区间和运行时调用路径的检查定位出以下热点：

1. **重复加载**：能力握手、试听和连续片段会重复进入模型访问路径。运行时现在按 model ID + manifest version 复用已验证 session；切换模型、不可恢复错误或空闲内存压力会卸载。
2. **生成复制**：长文本在单个 `[Float]` 中追加各子片段，峰值内存随生成音频增长。当前通过 token/字符/安全时长切片把单次结果限制在 60 秒以内；后续只有在 Instruments 证明复制仍为主要峰值来源时才改为流式 CAF 写入。
3. **GPU 同步与并发**：多个高内存 MLX 请求会争用统一内存和 Metal。调度器使用用户配置、运行时建议和模型安全上限三者最小值；speech-swift 当前安全上限为 1。
4. **取消竞态**：Metal kernel 不能总是立即终止。运行时停止后续片段提交，在每个安全边界再次检查取消并丢弃晚到结果，不写入 checkpoint。

对应单元测试覆盖同模型复用、模型切换、内存压力卸载、安全并发、长文本切片和取消晚到结果。最终性能结论仍必须来自固定环境的 Release 实机结果，而不是 Debug 或模拟 session。
