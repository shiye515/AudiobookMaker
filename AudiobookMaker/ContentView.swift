import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store: LibraryPresentationStore
    @State private var isImporterPresented = false
    @State private var isQueuePresented = false
    @State private var isDeletePresented = false

    init(mode: LibraryPresentationStore.Mode = .populated) {
        _store = State(initialValue: LibraryPresentationStore(mode: mode))
    }

    init(store: LibraryPresentationStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $store.columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 260)
        } content: {
            Group {
                switch store.section {
                case .books:
                    BookListView(store: store, importAction: presentImporter)
                case .models:
                    ModelListView(store: store)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 440)
        } detail: {
            Group {
                switch store.section {
                case .books:
                    if let book = store.selectedBook {
                        BookDetailView(
                            book: book,
                            primaryAction: { store.performPrimaryBookAction() },
                            deleteAction: { isDeletePresented = true },
                            queueAction: { isQueuePresented = true },
                            finderAction: { store.revealSelectedBookInFinder() },
                            retryChapterAction: { _ in store.performPrimaryBookAction() }
                        )
                    } else {
                        ContentUnavailableView(
                            "选择一本书",
                            systemImage: "books.vertical",
                            description: Text("从列表中选择书籍以查看章节和转换状态。")
                        )
                    }
                case .models:
                    if let model = store.selectedModel {
                        ModelDetailView(model: model) {
                            store.makeSelectedModelDefault()
                        }
                    } else {
                        ContentUnavailableView(
                            "选择一个模型",
                            systemImage: "waveform",
                            description: Text("查看模型框架、运行状态和能力。")
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 520)
        }
        .frame(minWidth: 720, minHeight: 540)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            QueueStatusBar(store: store) {
                isQueuePresented = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(store.section.title)
                    .font(.headline)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: presentImporter) {
                    if store.isImporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在导入 EPUB")
                    } else {
                        Label("导入 EPUB", systemImage: "plus")
                    }
                }
                .disabled(store.isImporting)
                .help("导入一本或多本 EPUB（⌘O）")
                .accessibilityIdentifier("toolbar.import")
                .accessibilityHint("打开文件选择器，可选择一本或多本 EPUB")
            }
            ToolbarItem(placement: .automatic) {
                if let book = store.selectedBook, book.status == .converting {
                    Label(
                        book.progress.formatted(.percent.precision(.fractionLength(0))),
                        systemImage: "waveform"
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("当前转换进度")
                    .accessibilityValue(book.progress.formatted(.percent))
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    isQueuePresented = true
                } label: {
                    Label("队列 \(store.queuedCount)", systemImage: "list.bullet.rectangle")
                }
                .help("显示转换队列")
                .accessibilityIdentifier("toolbar.queue")
                .accessibilityHint("打开当前排队和转换中的书籍列表")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let exported = store.lastExportedFileName {
                Label("导出完成：\(exported)", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(18)
                    .accessibilityIdentifier("export.completed")
            } else if let deletion = store.recentDeletion {
                HStack(spacing: 12) {
                    Text("已删除“\(deletion.title)”")
                    Button("撤销") { store.undoRecentDeletion() }
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 3)
                .padding(18)
                .accessibilityElement(children: .contain)
            }
        }
        .overlay {
            if store.isExporting {
                VStack(alignment: .leading, spacing: 12) {
                    Text("正在导出有声书")
                        .font(.headline)
                    ProgressView(value: store.exportProgress)
                        .frame(width: 320)
                        .accessibilityLabel("导出进度")
                        .accessibilityValue(store.exportProgress.formatted(.percent))
                    if let currentFile = store.exportCurrentFile {
                        Text(currentFile)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack {
                        Text(store.exportProgress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                        Spacer()
                        Button("取消导出", role: .cancel) { store.cancelExport() }
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 18, y: 8)
                .accessibilityElement(children: .contain)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                store.importBooks(from: urls)
            }
        }
        .sheet(isPresented: $isQueuePresented) {
            QueueSheet(store: store)
        }
        .confirmationDialog(
            "删除“\(store.selectedBook?.title ?? "这本书")”？",
            isPresented: $isDeletePresented
        ) {
            Button("删除 App 管理的数据", role: .destructive) {
                store.deleteSelectedBook()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除解析文本、临时文件和生成的音频，但不会删除原始 EPUB。")
        }
        .confirmationDialog(
            "这本书已经在资料库中",
            isPresented: Binding(
                get: { !store.duplicateImports.isEmpty },
                set: { _ in }
            )
        ) {
            Button("显示已有书籍") { store.locateExistingDuplicate() }
            Button("仍然创建副本") { store.createDuplicateImport() }
            Button("取消", role: .cancel) { store.cancelDuplicateImport() }
        } message: {
            Text("“\(store.duplicateImports.first?.sourceName ?? "所选 EPUB")”的内容与已有书籍相同。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .importEPUB)) { _ in
            presentImporter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showConversionQueue)) { _ in
            isQueuePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .startOrContinueConversion)) { _ in
            store.performPrimaryBookAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pauseConversion)) { _ in
            store.pauseSelectedBook()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedBook)) { _ in
            if store.selectedBook != nil { isDeletePresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportSelectedBook)) { _ in
            store.exportSelectedBook()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            let width = window.contentLayoutRect.width
            if width < 900 {
                store.columnVisibility = .detailOnly
            } else if width > 1_050, store.columnVisibility == .detailOnly {
                store.columnVisibility = .all
            }
        }
        .onOpenURL { url in
            store.importBooks(from: [url])
        }
        .task {
            await store.load()
            if ProcessInfo.processInfo.arguments.contains("--uitest-narrow-window") {
                store.columnVisibility = .detailOnly
                await Task.yield()
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.contentMinSize = NSSize(width: 720, height: 540)
                    window.setContentSize(NSSize(width: 760, height: 600))
                }
            }
        }
        .alert(
            "操作未完成",
            isPresented: Binding(
                get: { store.importErrorMessage != nil },
                set: { if !$0 { store.importErrorMessage = nil } }
            )
        ) {
            Button("好") { store.importErrorMessage = nil }
        } message: {
            Text(store.importErrorMessage ?? "未知错误")
        }
    }

    private func presentImporter() {
        store.section = .books
        isImporterPresented = true
    }
}

private struct SidebarView: View {
    @Bindable var store: LibraryPresentationStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.section) {
                Section("资料库") {
                    Label("书籍", systemImage: "books.vertical")
                        .badge(store.books.count)
                        .tag(LibrarySection.books)
                    Label("模型", systemImage: "waveform")
                        .tag(LibrarySection.models)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("全部在本机处理")
                        .font(.caption)
                        .accessibilityIdentifier("sidebar.localProcessing.title")
                        .accessibilityLabel("全部在本机处理")
                    Text("书籍内容不会上传")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebar.localProcessing.detail")
                        .accessibilityLabel("书籍内容不会上传")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .padding(.bottom, 24)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.localProcessing")
        }
        .navigationTitle("AudiobookMaker")
    }
}

private struct BookListView: View {
    @Bindable var store: LibraryPresentationStore
    let importAction: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if store.books.isEmpty {
                ContentUnavailableView {
                    Label("尚未导入书籍", systemImage: "books.vertical")
                } description: {
                    Text("导入 EPUB 开始制作本地有声书。")
                } actions: {
                    Button("导入 EPUB", action: importAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("打开文件选择器导入 EPUB")
                }
            } else if store.filteredBooks.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                List(selection: $store.selectedBookID) {
                    ForEach(store.filteredBooks) { book in
                        BookRow(book: book)
                            .tag(book.id)
                            .contextMenu {
                                Button("开始或继续转换") {
                                    store.selectedBookID = book.id
                                    store.performPrimaryBookAction()
                                }
                                Divider()
                                Button("删除…", role: .destructive) {
                                    store.selectedBookID = book.id
                                    NotificationCenter.default.post(name: .deleteSelectedBook, object: nil)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("我的书籍")
        .searchable(text: $store.searchText, prompt: "搜索书名或作者")
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .focusBookSearch)) { _ in
            isSearchFocused = true
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("状态", selection: $store.filter) {
                        ForEach(BookFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    Label("筛选", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
            guard !epubs.isEmpty else { return false }
            store.importBooks(from: epubs)
            return true
        }
    }
}

private struct BookRow: View {
    let book: BookSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(book: book, size: CGSize(width: 48, height: 64))
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(book.author) · \(book.chapterCount) 章")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: book.progress)
                Label(book.status.label, systemImage: book.status.symbol)
                    .font(.caption)
                    .foregroundStyle(book.status.tint)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            format: String(localized: "accessibility.book.summary"),
            book.title,
            book.author,
            book.chapterCount,
            book.status.label
        ))
        .accessibilityValue(String(
            format: String(localized: "accessibility.book.progress"),
            Int(book.progress * 100)
        ))
        .accessibilityHint("选择以查看章节和转换操作")
        .accessibilityIdentifier("book.row.\(book.id.uuidString)")
    }
}

private struct BookDetailView: View {
    let book: BookSnapshot
    let primaryAction: () -> Void
    let deleteAction: () -> Void
    let queueAction: () -> Void
    let finderAction: () -> Void
    let retryChapterAction: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                BookCover(book: book, size: CGSize(width: 104, height: 144))
                VStack(alignment: .leading, spacing: 9) {
                    Text(book.title)
                        .font(.largeTitle.bold())
                    Text(book.author)
                        .foregroundStyle(.secondary)
                    Text("\(book.chapterCount) 章 · 约 \(book.estimatedHours) 小时 · 简体中文")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: book.progress)
                        .accessibilityLabel("书籍转换进度")
                        .accessibilityValue(book.progress.formatted(.percent))
                    HStack {
                        Label(book.status.detailLabel, systemImage: book.status.symbol)
                            .foregroundStyle(book.status.tint)
                        Spacer()
                        Text(book.progress, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Label("Apple 系统语音 · 本机运行", systemImage: "waveform.badge.checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 10) {
                    Button(book.status.primaryActionTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("book.primaryAction")
                        .accessibilityHint(String(
                            format: String(localized: "accessibility.book.primaryActionHint"),
                            book.status.primaryActionTitle
                        ))
                    Menu {
                        Button("显示转换队列", action: queueAction)
                        Button("在 Finder 中显示", systemImage: "folder", action: finderAction)
                        Divider()
                        Button("删除书籍…", role: .destructive, action: deleteAction)
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityIdentifier("book.moreActions")
                    .accessibilityLabel("更多操作")
                    .accessibilityHint("显示队列、Finder 和删除操作")
                }
            }
            .padding(28)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("章节")
                        .font(.title2.bold())
                    Spacer()
                    Text("\(book.completedChapterCount) / \(book.chapterCount) 已完成")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Table(book.chapters) {
                    TableColumn("序号") { chapter in
                        Text(chapter.index, format: .number.precision(.integerLength(2)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(44)
                    TableColumn("章节") { chapter in
                        Text(chapter.title)
                            .contextMenu {
                                if chapter.status == .failed {
                                    Button("重试此章节", systemImage: "arrow.clockwise") {
                                        retryChapterAction(chapter.id)
                                    }
                                }
                            }
                    }
                    TableColumn("时长") { chapter in
                        Text(chapter.duration ?? "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(70)
                    TableColumn("状态") { chapter in
                        Label(chapter.status.label, systemImage: chapter.status.symbol)
                            .foregroundStyle(chapter.status.tint)
                            .accessibilityLabel(String(
                                format: String(localized: "accessibility.chapter.status"),
                                chapter.index
                            ))
                            .accessibilityValue(chapter.status.label)
                            .accessibilityIdentifier("chapter.status.\(chapter.index)")
                    }
                    .width(min: 100, ideal: 120)
                }
            }
            .padding(20)
        }
        .navigationTitle(book.title)
    }
}

private struct BookCover: View {
    let book: BookSnapshot
    let size: CGSize
    @State private var coverImage: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(4, size.width * 0.08), style: .continuous)
                .fill(book.coverColor.opacity(0.88))
            if let coverImage {
                Image(decorative: coverImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .clipShape(
                        RoundedRectangle(cornerRadius: max(4, size.width * 0.08), style: .continuous)
                    )
            } else {
                Image(systemName: book.coverSymbol)
                    .font(.system(size: size.width * 0.32))
                    .foregroundStyle(.white.opacity(0.9))
                Text(book.shortTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
        .accessibilityLabel("《\(book.title)》封面")
        .task(id: book.coverURL) {
            guard let coverURL = book.coverURL else {
                coverImage = nil
                return
            }
            coverImage = await CoverThumbnailCache.shared.image(
                at: coverURL,
                maximumPixelSize: Int(max(size.width, size.height) * 2)
            )
        }
    }
}

private struct ModelListView: View {
    @Bindable var store: LibraryPresentationStore

    var body: some View {
        List(selection: $store.selectedModelID) {
            ForEach(store.models) { model in
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(model.isAvailable ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.name)
                            .font(.headline)
                        Text("\(model.framework) · \(model.runtimeStatus)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isDefault {
                        Label("默认", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
                .tag(model.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(
                    format: String(localized: "accessibility.model.summary"),
                    model.name,
                    model.framework
                ))
                .accessibilityValue(model.isDefault
                    ? String(
                        format: String(localized: "accessibility.model.defaultValue"),
                        model.runtimeStatus
                    )
                    : model.runtimeStatus)
                .accessibilityHint("选择以查看模型详情")
            }
        }
        .navigationTitle("模型")
    }
}

private struct ModelDetailView: View {
    let model: TTSModelSnapshot
    let makeDefault: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("模型", value: model.name)
                LabeledContent("标识", value: model.id)
                LabeledContent("框架", value: model.framework)
                LabeledContent("运行时", value: model.runtimeStatus)
                LabeledContent("支持语言", value: model.languages)
            } header: {
                Label("模型信息", systemImage: "waveform")
            }
            Section("默认模型") {
                if model.isDefault {
                    Label("当前默认模型", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if model.isAvailable {
                    Button("设为默认", action: makeDefault)
                } else {
                    Text("运行时尚未提供此模型")
                        .foregroundStyle(.secondary)
                }
            }
            Section("语音参数") {
                LabeledContent("音色", value: "模型默认")
                LabeledContent("语速", value: "模型默认")
                Text("自定义语音参数将在后续版本提供。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
        .padding()
    }
}

private struct QueueStatusBar: View {
    let store: LibraryPresentationStore
    let showQueue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Label("队列 \(store.queuedCount)", systemImage: "clock")
                    Text("·")
                    Text("转换中 \(store.activeCount)")
                    Text("·")
                    Text("已完成 \(store.completedCount)")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("queue.summary")
                .accessibilityLabel("转换队列摘要")
                .accessibilityValue(String(
                    format: String(localized: "accessibility.queue.summary"),
                    store.queuedCount,
                    store.activeCount,
                    store.completedCount
                ))
                Spacer()
                Button("查看队列", action: showQueue)
                    .buttonStyle(.link)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("queue.open")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.trailing, 20)
            .frame(height: 30)
            .background(.bar)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct QueueSheet: View {
    let store: LibraryPresentationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.books.filter { $0.status == .queued || $0.status == .converting }) { book in
                HStack {
                    Label(book.title, systemImage: book.status.symbol)
                    Spacer()
                    ProgressView(value: book.progress)
                        .frame(width: 140)
                        .accessibilityLabel(String(
                            format: String(localized: "accessibility.book.namedProgress"),
                            book.title
                        ))
                        .accessibilityValue(book.progress.formatted(.percent))
                    Text(book.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .navigationTitle("转换队列")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}

#Preview("宽窗口 · 转换中") {
    ContentView()
        .frame(width: 1180, height: 760)
}

#Preview("空资料库") {
    ContentView(mode: .empty)
        .frame(width: 1080, height: 700)
}

#Preview("窄窗口") {
    ContentView()
        .frame(width: 980, height: 640)
}

#Preview("已暂停") {
    ContentView(mode: .paused)
        .frame(width: 1180, height: 760)
}

#Preview("已完成") {
    ContentView(mode: .completed)
        .frame(width: 1180, height: 760)
}

#Preview("转换失败") {
    ContentView(mode: .failed)
        .frame(width: 1180, height: 760)
}
