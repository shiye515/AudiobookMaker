# Tasks: 音色中心 UI 视觉与交互全面重构

- [x] 1. 数据模型与辅助方法扩展
  - [x] 1.1 在 `TTSEngine.swift` 中为 `VoiceSample` 添加 `age: String?` 解码字段
  - [x] 1.2 在 `VoiceLibrary.swift` 中补充标签集辅助方法和各分类数量统计
- [x] 2. 界面视图重构 (`VoiceLibraryView.swift`)
  - [x] 2.1 构建全新顶部 Header 与 `CategoryPillBar`（胶囊样式、平滑切换、数量徽标）及圆角搜索框
  - [x] 2.2 实现 `VoiceAvatarView`（专属渐变、声学图腾、播放中呼吸脉冲环）
  - [x] 2.3 实现 `VoiceQuoteBox`（名篇台词排版引用块）
  - [x] 2.4 实现 `VoicePreviewBar` 与 `AnimatedSpectrumWaveform`（流媒体式试听控制条与动态跳动声波）
  - [x] 2.5 重构 `VoiceCardView` 布局与材质交互（消灭大蓝条、右上角默认徽章、Hover 悬浮效果）
  - [x] 2.6 实现搜索/筛选为空时的优雅 Empty State
- [x] 3. 验证与构建检查
  - [x] 3.1 运行 xcodebuild 验证代码编译无任何警告与错误
  - [x] 3.2 验证试听、打断、设为默认旁白、搜索及分类逻辑完整可用
