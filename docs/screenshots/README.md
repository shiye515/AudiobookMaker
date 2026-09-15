# 截图与演示素材

把界面截图、短演示 GIF 放在本目录，供 README 引用。

## 建议素材清单

| 文件名（建议） | 内容 | 用途 |
|----------------|------|------|
| `library.png` | 书架网格 + 封面 | README 首屏 |
| `book-detail.png` | 章节队列与进度 | 功能说明 |
| `import-epub.gif` | 拖入 EPUB → 节级章节列表 | 核心卖点 |
| `export-m4b.png` | 导出面板 | 导出说明 |
| `playback-bar.png` | 底部播放条 | 体验细节 |

## 制作提示

- 使用 macOS 系统截图（⌘⇧4 / ⌘⇧5），浅色模式即可
- 避免录到个人书名、真实隐私文本时可先用演示 EPUB
- GIF：系统「截屏」录屏后用 `ffmpeg` 或 [GIPHY Capture](https://giphy.com/apps/giphycapture) 压缩，目标 < 5MB
- 分辨率：窗口 1280–1600 宽较清晰

## README 引用示例

```markdown
![书架](docs/screenshots/library.png)
```
