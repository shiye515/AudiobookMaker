# M4B 技术验证记录

## 冻结参数

- 容器：`AVFileType.m4a`，交付扩展名 `.m4b`
- 音频：AAC-LC，44.1 kHz，单声道，目标码率 64 kbps
- 时长：30 秒
- 容器元数据：标题、艺术家、专辑、PNG 封面
- 章节：`tx3g` 文本轨，首个有效样本从 `t=0` 覆盖至音频结束，并通过 `AVAssetTrack.AssociationType.chapterList` 与主音频轨关联
- 正文：另一条独立 `tx3g` 文本轨，单个有效样本从 `t=0` 覆盖至音频结束

## 自动验证

`M4BSpikeTests.roundTrip()` 已使用 `AVURLAsset` 和 `AVAssetReader` 验证：

- 容器时长为 30 秒；
- 恰有一条 AAC-LC 音频轨；
- 通用元数据可回读标题和封面；
- 音频轨恰有一条 chapter-list 关联轨；
- 章节有效样本从 `t=0` 覆盖 30 秒，UTF-8 标题无损回读；
- 除章节轨外还存在独立全文轨，其唯一有效样本从 `t=0` 覆盖 30 秒，UTF-8 正文无损回读。

AVAssetReader 会额外暴露一个无数据、零样本的 edit-boundary buffer；它不是媒体样本，验证器必须忽略。

## 播放器验证

- QuickTime Player：已成功打开验收文件，识别容器标题 `AudiobookMaker Spike`，界面显示 `00:30` 总时长。
- QuickTime 实际播放推进：等待用户批准 macOS 的“控制 QuickTime Player”自动化权限后验证。
- Apple Books：等待交互式导入；该操作会修改用户的 Books 资料库，因此未在无确认情况下执行。

验收文件：[AudiobookMaker-M4B-Spike.m4b](AudiobookMaker-M4B-Spike.m4b)
