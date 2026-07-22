# speech-swift 中文人工听感验收单

自动音频结构校验、RTF 和 M4B 回读不能替代本验收。验收人应在同一台 Mac、同一副耳机、关闭空间音频与音效增强后，将每个文件完整播放两遍；任何一项不通过都不得勾选 OpenSpec 7.7，也不得静默更换 voice 或试听文案。

## 冻结候选

| 模型 | 固定 model ID / version | 默认 voice | 固定产品试听文案 |
| --- | --- | --- | --- |
| CosyVoice3 | `soniqo.speech-swift/cosyvoice3-0.5b-mlx-8bit-full` / `b52fc1c3bf5f3b947d40c250639e5ebe347ece11` | `default` | “你好，这是无需联网的本机语音模型固定试听。” |
| Qwen3-TTS | `soniqo.speech-swift/qwen3-tts-12hz-0.6b-customvoice-mlx-bf16` / `3affbf656d9d6aa9255ec0b31cc90055605170bc` | `vivian` | “你好，这是无需联网的本机语音模型固定试听。” |

## 固定样本与判定标准

每个模型的 `ApplicationSupport/AcceptanceEvidence` 目录包含同名文件：

| 文件 | 固定输入 | 必须确认 |
| --- | --- | --- |
| `01-numbers.caf` | “二〇二六年七月二十二日，人民币一百二十三元四角五分。” | 年月日、金额、量词无漏读、错读或异常停顿 |
| `02-names.caf` | “李光耀谈中国、美国与东南亚未来的长期关系。” | “李光耀”、国家与“东南亚”发音自然清楚 |
| `03-mixed.caf` | “AudiobookMaker 使用 Apple Silicon 和 MLX 在本机生成语音。” | 三个英文/缩写与中文切换可理解，无吞字或长静音 |
| `04-boundary.caf` | “第一章结束。\n\n第二章开始，这是章节边界试听。” | 两章边界停顿明确但不过长，第二章开头不截断 |
| `05-preview.caf` | 固定产品试听文案 | 音色、音量与节奏适合作为模型页试听基线 |
| `real-epub-long-chunk.caf` | 真实 EPUB 最长章节前 450 字 | 长段落无重复、跳字、爆音、音量漂移或逐步失速 |
| `offline-restart.caf` | “模型安装完成后，应用只从已校验的本地目录恢复合成。” | 重载前后音色一致，无网络依赖造成的异常 |

CosyVoice3 目录：
`build/acceptance/speech-swift/runtime/soniqo.speech-swift--cosyvoice3-0.5b-mlx-8bit-full/ApplicationSupport/AcceptanceEvidence/`

Qwen3-TTS 目录（完成实机运行后生成）：
`build/acceptance/speech-swift/runtime/soniqo.speech-swift--qwen3-tts-12hz-0.6b-customvoice-mlx-bf16/ApplicationSupport/AcceptanceEvidence/`

## 验收记录

- 验收人：
- 日期与时区：
- Mac 型号 / macOS：
- 播放设备与音效设置：
- CosyVoice3：数字 [ ] 专名 [ ] 中英混排 [ ] 章节边界 [ ] 长段落 [ ] 重载一致性 [ ]
- Qwen3-TTS：数字 [ ] 专名 [ ] 中英混排 [ ] 章节边界 [ ] 长段落 [ ] 重载一致性 [ ]
- 问题与时间点：
- 结论：CosyVoice3 [ ] 通过 [ ] 阻止发布；Qwen3-TTS [ ] 通过 [ ] 阻止发布
- 确认默认 voice 与固定试听文案保持上表值：[ ]
