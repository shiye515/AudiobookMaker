//
//  LibraryGridView.swift
//  abm
//
//  书架：紧凑实体精装书卡片（固定 135pt 不拉伸）+ FlowLayout 严格左对齐 + 书脊装帧微光影 + 统计Header。
//

import SwiftUI

struct LibraryGridView: View {
    let store: AppStore

    var body: some View {
        let books = store.filteredBooks()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerArea

                if !store.failedManifestBookIDs.isEmpty {
                    failedManifestBanner
                }

                if books.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 60)
                } else {
                    FlowLayout(horizontalSpacing: 22, verticalSpacing: 24) {
                        ForEach(books) { book in
                            BookCardView(book: book, isQueued: store.isBookQueuedOnly(book))
                                .onTapGesture { store.route = .bookDetail(book.id) }
                                .contextMenu {
                                    Button("进入书籍详情") {
                                        store.route = .bookDetail(book.id)
                                    }
                                    Button("打开书籍目录") {
                                        if let url = LibraryStore.coverURL(for: book) {
                                            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                                        }
                                    }
                                    Divider()
                                    Button("删除书籍", role: .destructive) {
                                        store.deleteBook(book.id)
                                    }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 顶部标题与书架统计

    private var headerArea: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filterTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)

                Text(filterSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var filterTitle: String {
        switch store.libraryFilter {
        case .all: return "我的书架"
        case .generating: return "正在生成"
        case .finished: return "已完成图书"
        }
    }

    private var filterSubtitle: String {
        let books = store.books
        let finished = books.filter(\.isFinished).count
        let generating = books.filter(\.isGenerating).count
        let generatingOrQueued = store.generatingBookCount
        switch store.libraryFilter {
        case .all:
            return "共 \(books.count) 本图书 · \(finished) 本已就绪 · \(generatingOrQueued) 本生成中或排队"
        case .generating:
            return "当前有 \(generatingOrQueued) 本图书正在合成或排队等待（\(generating) 本合成中）"
        case .finished:
            return "共 \(finished) 本图书已就绪，可随时试听播放或导出 M4B / MP3"
        }
    }

    // MARK: - 结构升级断档提示

    private var failedManifestBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("有 \(store.failedManifestBookIDs.count) 本书因章节结构升级无法加载")
                    .font(.subheadline.weight(.semibold))
                Text("请重新导入对应 EPUB 以恢复节级章节列表；旧音频目录在覆盖前仍保留在数据文件夹中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
        )
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 80, height: 80)
                Image(systemName: "books.vertical")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }

            Text(store.books.isEmpty ? "书架还是空的" : "当前筛选没有图书")
                .font(.title3.weight(.medium))

            Text("点击右上角「导入 EPUB」或直接将 .epub 文件拖入窗口任意位置")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let status = store.importStatus {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(40)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 精炼固定尺寸卡片（不做响应式缩放，严格左对齐）

struct BookCardView: View {
    let book: BookProject
    var isQueued: Bool = false
    @State private var isHovered = false

    private let cardWidth: CGFloat = 135
    private let coverHeight: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 实体书精装封面
            BookCoverView(book: book, isHovered: isHovered, width: cardWidth, height: coverHeight)

            // 书名（固定 2 行高度 36pt，使整行下沿严格对齐）
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(width: cardWidth, height: 36, alignment: .topLeading)

            // 作者与字数
            HStack(spacing: 4) {
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(wordCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: cardWidth, alignment: .leading)

            // 状态栏
            statusArea
                .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - 状态指示

    @ViewBuilder
    private var statusArea: some View {
        if book.isGenerating {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: book.progress)
                    .tint(Color.accentColor)
                    .controlSize(.mini)

                HStack(spacing: 3) {
                    Text("合成中 \(book.doneCount)/\(book.chapters.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("\(Int(book.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else if isQueued {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)

                Text("排队中")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)

                Text("· 预估 \(estimatedHours)h")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if book.isFinished {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)

                Text("已就绪")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)

                if let duration = totalDurationText {
                    Text("· \(duration)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 3) {
                Text("待生成")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("· 预估 \(estimatedHours)h")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var totalDurationText: String? {
        let total = book.chapters.compactMap(\.durationSeconds).reduce(0, +)
        guard total > 0 else { return nil }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)分"
    }

    private var wordCountText: String {
        book.totalWordCount >= 10_000
            ? "\(book.totalWordCount / 10_000)万字"
            : "\(book.totalWordCount)字"
    }

    private var estimatedHours: String {
        let hours = Double(book.totalWordCount) / 42_000.0
        return hours < 0.1 ? "<0.1" : String(format: "%.1f", hours)
    }
}

// MARK: - 实体书装帧封面（固定尺寸）

private struct BookCoverView: View {
    let book: BookProject
    let isHovered: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            // 封面图像
            Group {
                if let coverURL = LibraryStore.coverURL(for: book),
                   let image = NSImage(contentsOf: coverURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholderCover
                }
            }
            .frame(width: width, height: height)
            .clipped()

            // 逼真书脊阴影（左侧暗部压痕，模拟装订线与立体厚度）
            HStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.32),
                        Color.black.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 7)

                Spacer()
            }

            // 表面哑光微反光（右上角柔和渐变微光）
            LinearGradient(
                colors: [
                    Color.white.opacity(0.12),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: .center
            )
            .allowsHitTesting(false)

            // 右上角状态徽标（已就绪微型胶囊）
            VStack {
                HStack {
                    Spacer()
                    if book.isFinished {
                        HStack(spacing: 2.5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                            Text("已就绪")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.primary)
                        .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)
                        .padding(6)
                    }
                }
                Spacer()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            // 封皮外沿极细描边（杜绝纯白封面与浅色背景融为一体）
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.8)
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.20 : 0.10),
            radius: isHovered ? 10 : 4,
            x: 0,
            y: isHovered ? 5 : 2
        )
        .offset(y: isHovered ? -3 : 0)
        .animation(.snappy(duration: 0.2), value: isHovered)
    }

    private var placeholderCover: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.28, green: 0.32, blue: 0.42), Color(red: 0.18, green: 0.22, blue: 0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.75))

                Text(book.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
    }
}

// MARK: - 严格左对齐流式布局（FlowLayout）

struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 20
    var verticalSpacing: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        guard width > 0, width.isFinite else { return .zero }

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        guard width > 0 else { return }

        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
