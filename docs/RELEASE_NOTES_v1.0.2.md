# v1.0.2 — 第二个公开版本

在 [v1.0.0](https://github.com/shiye515/AudiobookMaker/releases/tag/v1.0.0) 之上：章节拆分更准、导出链路更稳，并完成完整开源协作文档。

**变更摘要见 [CHANGELOG](CHANGELOG.md)** · **使用说明见 [README](README.md)**

---

## 本版亮点

### 1. EPUB 章节拆分升级（重点）

- 按目录**最小节**拆分：支持同一 HTML 文件内的锚点分节  
- 标题保留层级，例如 `中国 · 新中国：人民、社会、经济`  
- 针对 **Calibre 等脏目录**（NCX 与正文错位、`#calibre_pb_*` 伪锚点）：以正文首行纠正标题，避免「章节名对不上内容」  
- 无可靠锚点时退回「一文件一章」，不乱切  

可用无头命令自检一本书：

```bash
path/to/abm.app/Contents/MacOS/abm --verify-epub-split /path/to/book.epub
```

### 2. 导出与分发更稳

- 内置 ffmpeg 以 **Hardened Runtime** 签名（解决公证/上传校验问题）  
- speech-swift 本地化并修正 `Float16`，**Xcode 菜单 Product → Archive 可直接使用**  
- 导出章节名使用全路径；试听播放条仍显示短标题  

### 3. 体验

- 侧栏「正在生成」**包含排队中的书**，并显示「排队中」状态  
- 书架副标题区分「合成中 / 排队」  

### 4. 开源与协作

- MIT 许可、`NOTICE`、贡献指南、安全披露、行为准则  
- Issue / PR 模板、macOS CI、FAQ、截图与本 Release 文档  

---

## 安装

### 源码（推荐）

```bash
git clone https://github.com/shiye515/AudiobookMaker.git
cd AudiobookMaker
git checkout v1.0.2   # 或 main
open abm.xcodeproj
```

`⌘R` 运行 → 初始化模型 → 导入 EPUB → 生成 → 导出。  
M4B 需先：`scripts/build-ffmpeg.sh`

### 预编译包

若本页附件含公证后的 zip：解压 → 拖入「应用程序」→ 首次右键打开。  
无附件则请从源码构建。

---

## 系统要求

- **Apple Silicon**（不支持 Intel）  
- macOS 15+  
- 建议 16 GB+ 内存；模型约 2 GB+（首次下载）  

## 从 1.0.x 升级

- 直接用新版本覆盖安装或重新从源码构建即可  
- 若升级后书架书提示「结构升级需重新导入」：用**原 EPUB 重新导入**（章节列表会更新；音频需重新合成）  
- 书库数据目录在覆盖前仍保留  

## 已知限制

1. 仅 Apple Silicon / macOS；无 App Store 沙箱版  
2. 首次模型下载体积与内存占用较大  
3. 个别制作极差的 EPUB 章节粒度仍可能不理想  
4. 不提供 MP3 导出（M4B / M4A / WAV）  
5. 无 iOS 版；手机端通过导出 M4B 同步到「图书」收听  

## 反馈

- [Issues](https://github.com/shiye515/AudiobookMaker/issues) / [Discussions](https://github.com/shiye515/AudiobookMaker/discussions)  
- 章节问题请附 `--verify-epub-split` 输出  
- 安全：见 [SECURITY.md](https://github.com/shiye515/AudiobookMaker/blob/main/SECURITY.md)  

欢迎 Star、Issue 与 PR。

## 致谢

speech-swift、MLX、ZIPFoundation、FFmpeg 及 CosyVoice 相关模型与托管方。条款见 `LICENSE` / `NOTICE`。
