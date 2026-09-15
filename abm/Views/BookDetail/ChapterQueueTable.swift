//
//  ChapterQueueTable.swift
//  abm
//
//  章节队列表格：消灭满屏大绿条 + 精致状态胶囊 + 播放中高亮律动 + 悬停操作组 + 工具栏统揽。
//

import SwiftUI

struct ChapterQueueTable: View {
    let book: BookProject
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 表格工具栏：章节统计与目录直达
            tableHeaderBar

            // 现代化数据表格
            Table(book.chapters) {
                // 1. 序号
                TableColumn("序号") { chapter in
                    Text("\(chapter.index)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .width(min: 32, ideal: 36, max: 45)

                // 2. 章节名称（播放中带高亮与声波）
                TableColumn("章节名称") { chapter in
                    chapterNameCell(chapter)
                }
                .width(min: 160, ideal: 240)

                // 3. 字数
                TableColumn("字数") { chapter in
                    Text("\(chapter.wordCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60, max: 75)

                // 4. 状态与进度（彻底消灭全屏粗暴大绿条）
                TableColumn("状态") { chapter in
                    statusAndProgressCell(chapter)
                }
                .width(min: 75, ideal: 85, max: 100)

                // 6. 音频时长
                TableColumn("音频时长") { chapter in
                    audioDurationCell(chapter)
                }
                .width(min: 75, ideal: 85, max: 100)

                // 7. 操作组
                TableColumn("操作") { chapter in
                    actionButtonsCell(chapter)
                }
                .width(min: 44, ideal: 50, max: 60)
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            .defaultScrollAnchor(.top)
            .background(TableHorizontalScrollerDisabler())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 表格工具栏

    private var tableHeaderBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("章节队列")
                .font(.headline.weight(.semibold))

            Text("共 \(book.chapters.count) 章 · \(book.doneCount) 章已就绪")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

            Spacer()
        }
    }

    // MARK: - 单元格组件

    private func chapterNameCell(_ chapter: Chapter) -> some View {
        let playing = isPlaying(chapter: chapter)

        return HStack(spacing: 6) {
            if playing {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(chapter.fullTitle)
                .font(.body.weight(playing ? .semibold : .regular))
                .foregroundStyle(playing ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .help(chapter.fullTitle)
        }
    }

    @ViewBuilder
    private func statusAndProgressCell(_ chapter: Chapter) -> some View {
        switch chapter.status {
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("已就绪")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.green.opacity(0.12)))

        case .generating:
            let progress = store.chapterProgress(book: book, chapter: chapter)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("合成中 \(Int(progress * 100))%")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .frame(width: 70, height: 3)
            }

        case .waiting:
            if let done = chapter.completedSegments, let total = chapter.totalSegments, done > 0 {
                HStack(spacing: 3) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                    Text("已存 \(done)/\(total) 段")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(store.isQueuePaused ? "已暂停" : "等待中")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                    .foregroundStyle(.secondary)
            }

        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                Text("失败")
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.12)))
            .foregroundStyle(.red)
        }
    }

    private func audioDurationCell(_ chapter: Chapter) -> some View {
        Group {
            if let duration = chapter.durationSeconds {
                HStack(spacing: 3) {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(Self.durationText(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func actionButtonsCell(_ chapter: Chapter) -> some View {
        let playing = isPlaying(chapter: chapter)

        return Group {
            // 试听播放 / 暂停
            if chapter.status == .done {
                Button {
                    if playing {
                        store.player.stop()
                    } else {
                        store.playChapter(book: book, chapter: chapter)
                    }
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(playing ? Color.accentColor : Color.primary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(playing ? "停止试听" : "试听此章节")
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func isPlaying(chapter: Chapter) -> Bool {
        store.player.contextID == "\(book.id)/\(chapter.id)" && store.player.isPlaying
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d分%02d秒", total / 60, total % 60)
    }
}

// MARK: - 禁用表格水平滚动条

private struct TableHorizontalScrollerDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view = view else { return }
            Self.disableScroller(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView = nsView else { return }
            Self.disableScroller(from: nsView)
        }
    }

    private static func disableScroller(from view: NSView) {
        var current: NSView? = view
        while let v = current {
            if let sv = findScrollView(in: v) {
                if sv.hasHorizontalScroller {
                    sv.hasHorizontalScroller = false
                }
                return
            }
            current = v.superview
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }
}
