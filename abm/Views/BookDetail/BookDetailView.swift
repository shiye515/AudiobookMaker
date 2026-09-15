//
//  BookDetailView.swift
//  abm
//
//  图书详情工作台：精装实体书封面 + 全局合成进度主仪表 + 遥测指标卡片 + 章节队列表格 + 导出入口。
//

import SwiftUI

struct BookDetailView: View {
    let bookID: String
    let store: AppStore
    @State private var showExportSheet = false
    @State private var showResetConfirm = false
    @State private var showDeleteConfirm = false

    private var book: BookProject? { store.book(id: bookID) }

    var body: some View {
        Group {
            if let book {
                VStack(alignment: .leading, spacing: 18) {
                    BookHeaderCardView(book: book, store: store)

                    ChapterQueueTable(book: book, store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("书籍不存在或已被删除")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button("返回书架") {
                        store.route = .library
                    }
                    .buttonStyle(RoundedRectButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { detailToolbar(book) }
        .removeToolbarBezels(trigger: "\(book?.isGenerating ?? false)-\(store.isQueuePaused)-\(bookID)-\(book?.isFinished ?? false)")
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(book: book, store: store)
        }
        .alert("确认重置书籍生成？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) { }
            Button("重置生成", role: .destructive) {
                if let book {
                    store.resetBook(book.id)
                }
            }
        } message: {
            Text("将清空《\(book?.title ?? "")》所有已生成的章节音频与进度，恢复为初始状态。重置后可重新更换音色并再次生成全书。")
        }
        .alert("确认删除书籍？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除书籍", role: .destructive) {
                if let book {
                    store.deleteBook(book.id)
                }
            }
        } message: {
            Text("此操作将从书架中移除《\(book?.title ?? "")》，并彻底删除应用数据目录下该书籍的所有文本、音频及缓存文件，此操作不可撤销。")
        }
        .onAppear {
            if book != nil { store.beginExport(bookID: bookID) }
        }
    }

    @ToolbarContentBuilder
    private func detailToolbar(_ book: BookProject?) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                store.route = .library
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("书架")
                        .font(.subheadline)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回书架")
        }

        ToolbarItem(placement: .primaryAction) {
            if let book {
                HStack(spacing: 8) {
                    if book.isGenerating {
                        Button {
                            store.pauseQueue()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 11))
                                Text("暂停全部")
                            }
                            .roundedRectChrome()
                        }
                        .buttonStyle(.plain)
                    } else if store.isQueuePaused && store.pendingQueue.contains(where: { $0.bookID == book.id }) {
                        Button {
                            store.resumeQueue()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                Text("继续生成")
                            }
                            .roundedRectChrome(prominent: true)
                        }
                        .buttonStyle(.plain)
                    } else if book.isFinished {
                        Button {
                            showResetConfirm = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                                Text("重置生成")
                            }
                            .roundedRectChrome()
                        }
                        .buttonStyle(.plain)
                        .help("清空已生成的全部章节音频，重置为默认状态以重新生成")
                    } else {
                        Button {
                            store.generateBook(book.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 11))
                                Text(hasStartedGeneration(book) ? "继续生成" : "一键生成全书")
                            }
                            .roundedRectChrome(prominent: true)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showExportSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11))
                            Text("导出有声书")
                        }
                        .roundedRectChrome()
                    }
                    .buttonStyle(.plain)
                    .disabled(book.doneCount == 0)

                    Button {
                        showDeleteConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("删除书籍")
                        }
                        .roundedRectChrome()
                    }
                    .buttonStyle(.plain)
                    .help("彻底删除此书籍及其所有本地数据")
                }
                .padding(.trailing, 16)
            }
        }
    }

    private func hasStartedGeneration(_ book: BookProject) -> Bool {
        book.doneCount > 0 || book.chapters.contains { ($0.completedSegments ?? 0) > 0 }
    }
}

// MARK: - 图书概要与进度仪表卡

struct BookHeaderCardView: View {
    let book: BookProject
    let store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // 实体书精装封面
            bookCover

            // 中部：书名 + 统计元数据 + 全局合成进度条 + 默认音色选择器
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(book.author.isEmpty ? "未知作者" : book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(wordCount)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text("\(book.chapters.count) 章节")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 全书总进度条与状态文案
                masterProgressSection

                // 默认音色选择器胶囊
                defaultVoiceMenu
            }

            Spacer(minLength: 20)

            // 右侧：遥测指标卡片组（2x2 网格）
            telemetryDashboard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // MARK: - 实体书封面

    private var bookCover: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let coverURL = LibraryStore.coverURL(for: book),
                   let image = NSImage(contentsOf: coverURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                }
            }
            .frame(width: 84, height: 118)
            .clipped()

            // 书脊逼真阴影
            HStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.30), Color.black.opacity(0.10), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 6)
                Spacer()
            }

            // 哑光微反光
            LinearGradient(
                colors: [Color.white.opacity(0.15), Color.clear],
                startPoint: .topTrailing, endPoint: .center
            )
            .allowsHitTesting(false)
        }
        .frame(width: 84, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 5, y: 2.5)
    }

    // MARK: - 全书进度指示区

    private var masterProgressSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // 细胶囊进度条
                ProgressView(value: book.progress)
                    .tint(book.isFinished ? Color.green : Color.accentColor)
                    .frame(width: 120)

                Text("\(Int(book.progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(book.isFinished ? .green : .secondary)
            }

            HStack(spacing: 6) {
                if book.isFinished {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text("全书已生成完毕")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }

                    if let totalDur = totalDurationText {
                        Text("· 累计音频时长 \(totalDur)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if book.isGenerating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("正在生成: \(book.doneCount)/\(book.chapters.count) 章节已就绪")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                } else if store.isBookQueuedOnly(book) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Text("排队中，等待当前任务完成后自动开始")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    Text("\(book.doneCount)/\(book.chapters.count) 章节已生成 · 预估剩余 \(store.etaText(for: book))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var totalDurationText: String? {
        let total = book.chapters.compactMap(\.durationSeconds).reduce(0, +)
        guard total > 0 else { return nil }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分"
        }
        return "\(minutes)分钟"
    }

    // MARK: - 默认音色菜单

    private var defaultVoiceMenu: some View {
        Menu {
            ForEach(store.voiceLibrary.voices) { voice in
                Button {
                    updateDefaultVoice(voice.name)
                } label: {
                    HStack {
                        Text("\(voice.name) · \(voice.trait)")
                        if voice.name == book.defaultVoiceName {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(book.isInitialState ? Color.accentColor : Color.secondary)

                Text("默认音色: \(book.defaultVoiceName)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(book.isInitialState ? .primary : .secondary)

                if book.isInitialState {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(book.isInitialState ? 0.05 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(book.isInitialState ? 0.10 : 0.05), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(!book.isInitialState)
        .help(book.isInitialState ? "更改默认旁白音色" : "书籍已开始生成或已生成，音色已锁定（需重置生成后更改）")
        .fixedSize()
    }

    private func updateDefaultVoice(_ newVoice: String) {
        if let index = store.books.firstIndex(where: { $0.id == book.id }) {
            store.books[index].defaultVoiceName = newVoice
            try? LibraryStore.save(store.books[index])
        }
    }

    // MARK: - 遥测仪表盘（4 格指标小卡片）

    private var telemetryDashboard: some View {
        HStack(spacing: 10) {
            VStack(spacing: 8) {
                metricTile(
                    title: "合成倍速 (RTF)",
                    value: store.isReady && store.queueRecentRTF > 0 ? String(format: "%.2fx", store.queueRecentRTF) : (store.isReady ? "就绪" : "—"),
                    icon: "bolt.fill",
                    color: .orange
                )
                metricTile(
                    title: "预估剩余",
                    value: store.etaText(for: book),
                    icon: "hourglass",
                    color: .purple
                )
            }
            VStack(spacing: 8) {
                metricTile(
                    title: "已用时",
                    value: store.queueElapsedText,
                    icon: "clock.fill",
                    color: .blue
                )
                metricTile(
                    title: "显存/内存",
                    value: "\(store.memoryMB) MB",
                    icon: "memorychip",
                    color: .green
                )
            }
        }
    }

    private func metricTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 105, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var wordCount: String {
        book.totalWordCount >= 10_000
            ? "\(book.totalWordCount / 10_000)万字" : "\(book.totalWordCount)字"
    }
}
