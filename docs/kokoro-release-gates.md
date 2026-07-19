# Kokoro 发布门禁

本文件用于完成 OpenSpec `adopt-sherpa-kokoro` 的 4.6、8.2 和 8.4。只有实际证据生成并审核后才能勾选对应任务。

Intel 对照证据已由同一脚本生成在 `build/acceptance/kokoro-x86_64-host-final/`，其中原生基准架构为 `x86_64`、真实 Kokoro 测试 1/1 通过。Apple Silicon 验收必须使用下述相同命令和模型哈希生成独立 `arm64` 证据，不能以通用二进制包含 arm64 slice 代替原生运行。

## Apple Silicon 实机（4.6、8.2）

前提：在 Apple Silicon Mac 上检出同一提交，并准备官方 `kokoro-int8-multi-lang-v1_1.tar.bz2`。先确认：

```sh
test "$(uname -m)" = arm64
```

运行固定口径原生基准和 Swift 运行时冒烟测试：

```sh
Tools/Smoke/run-kokoro-host-acceptance.sh \
  /path/to/kokoro-int8-multi-lang-v1_1.tar.bz2 \
  build/acceptance/kokoro-arm64
```

验收人需要保存并审阅：

- `environment.txt`：主机必须为 `arm64`，模型 SHA-256 必须与签名清单一致。
- `benchmark.txt`：必须包含冷加载、首段延迟、RTF、长段稳定性、取消响应和内存数据，且 `architecture=arm64`。
- `audio/*.wav`：必须可由 `afinfo` 回读。
- `Kokoro-Host-Smoke.xcresult`：真实 Kokoro 测试必须通过，覆盖合成、取消、超时和输出音频校验。
- Activity Monitor 或 `ps` 证据：运行中的 App/基准进程 Kind/Architecture 必须为 Apple。

随后使用 Developer ID 对最终通用 App 归档、导出并公证；保存 `codesign --verify --deep --strict`、`spctl --assess --type execute`、`stapler validate` 的成功输出。启动公证后的 App，确认 App Sandbox 下可由用户明确触发模型下载，安装后断网仍可试听和转换。

没有 Apple Silicon 实机运行结果或 Developer ID 公证结果时，不得完成 4.6/8.2。

## 人工听感（8.4）

使用 `build/acceptance/kokoro-listening-acceptance/` 中五个 WAV，佩戴同一耳机、关闭系统音效增强，以正常语速完整听两遍：

| 文件 | 检查内容 | 通过标准 |
| --- | --- | --- |
| `01-numbers-money.wav` | 百分比、整数、小数、金额 | 数值与单位完整，无丢字、倒序或错误断句 |
| `02-date-time.wav` | 日期与时间 | 年月日、时分完整且自然 |
| `03-proper-names.wav` | 李光耀、国家与产品专名 | 专名可辨认，无明显错音或漏音 |
| `04-mixed-language.wav` | 中文、英文、版本号混排 | 语言切换可理解，不吞词 |
| `05-chapter-boundary.wav` | 章节结尾与下一章开头 | 边界停顿清楚，不粘连、不截断 |

试听中特别留意生成日志记录的未知音素 `U+025A`。任一关键数值、日期、专名或章节边界不可理解即判失败；记录具体文件和时间点，不得以波形有效或自动化测试代替人工听感。

通过后在验收报告记录：验收人、日期、播放设备、五项结果和问题说明，并确认默认音色仍为 `zf_001`（speaker ID 3）、固定中文试听样句仍为“你好，这是本地音色试听。”。试听文案不得混入会生成未知 token/音素的 `〇` 或英文品牌名。
