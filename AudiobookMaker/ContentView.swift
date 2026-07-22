import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store: LibraryPresentationStore
    @State private var isImporterPresented = false
    @State private var isQueuePresented = false
    @State private var isDeletePresented = false
    @State private var pauseKeyMonitor: Any?

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
                            modelLabel: store.modelLabel(for: book),
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
                        ModelDetailView(model: model, store: store)
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
            if store.section == .books {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: presentImporter) {
                        if store.isImporting {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("导入中")
                            }
                            .accessibilityLabel("正在导入 EPUB")
                        } else {
                            Text("导入")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isImporting)
                    .help("导入一本或多本 EPUB（⌘O）")
                    .accessibilityIdentifier("toolbar.import")
                    .accessibilityHint("打开文件选择器，可选择一本或多本 EPUB")
                }
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
        .sheet(isPresented: exportDialogPresented) {
            ExportProgressDialog(store: store)
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
        .modifier(ModelSelectionCommandModifier(store: store))
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
            if ProcessInfo.processInfo.arguments.contains("--uitest-fixed-window"),
               let window = NSApp.windows.first(where: { $0.isVisible }),
               let screen = NSScreen.screens.first {
                let size = NSSize(width: 1_180, height: 760)
                let visibleFrame = screen.visibleFrame
                let origin = NSPoint(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.midY - size.height / 2
                )
                window.setFrame(NSRect(origin: origin, size: size), display: true)
            }
            if ProcessInfo.processInfo.arguments.contains("--uitest-narrow-window") {
                store.columnVisibility = .detailOnly
                await Task.yield()
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.contentMinSize = NSSize(width: 720, height: 540)
                    window.setContentSize(NSSize(width: 760, height: 600))
                }
            }
        }
        .onAppear {
            guard pauseKeyMonitor == nil else { return }
            pauseKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers == .command, event.charactersIgnoringModifiers == "." else { return event }
                store.pauseSelectedBook()
                return nil
            }
        }
        .onDisappear {
            if let pauseKeyMonitor { NSEvent.removeMonitor(pauseKeyMonitor) }
            pauseKeyMonitor = nil
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

    private var exportDialogPresented: Binding<Bool> {
        Binding(
            get: { store.isExporting },
            set: { _ in }
        )
    }
}

private struct ModelSelectionCommandModifier: ViewModifier {
    @Bindable var store: LibraryPresentationStore

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .selectSystemModel)) { _ in
                select(TTSModelCatalog.systemID, makeDefaultWhenAvailable: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectKokoroModel)) { _ in
                select(TTSModelCatalog.kokoroID, makeDefaultWhenAvailable: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectCosyVoiceModel)) { _ in
                select(TTSModelCatalog.cosyVoiceID, makeDefaultWhenAvailable: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectQwen3TTSModel)) { _ in
                select(TTSModelCatalog.qwen3TTSID, makeDefaultWhenAvailable: true)
            }
    }

    private func select(_ modelID: String, makeDefaultWhenAvailable: Bool) {
        store.section = .models
        store.selectedModelID = modelID
        if makeDefaultWhenAvailable, store.selectedModel?.isAvailable == true {
            store.makeSelectedModelDefault()
        }
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
    }
}

private struct BookListView: View {
    @Bindable var store: LibraryPresentationStore
    let importAction: () -> Void

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
    let modelLabel: String
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
                    Label(modelLabel, systemImage: "waveform.badge.checkmark")
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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Label(chapter.status.label, systemImage: chapter.status.symbol)
                                    .foregroundStyle(chapter.status.tint)
                                if let progress = chapter.progress {
                                    Spacer(minLength: 4)
                                    Text(progress, format: .percent.precision(.fractionLength(0)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            if let progress = chapter.progress {
                                ProgressView(value: progress)
                                    .controlSize(.small)
                                    .accessibilityLabel("第 \(chapter.index) 章转换进度")
                                    .accessibilityValue(progress.formatted(.percent))
                                    .accessibilityIdentifier("chapter.progress.\(chapter.index)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(String(
                            format: String(localized: "accessibility.chapter.status"),
                            chapter.index
                        ))
                        .accessibilityValue(chapter.progress.map {
                            "\(chapter.status.label)，\($0.formatted(.percent))"
                        } ?? chapter.status.label)
                        .accessibilityIdentifier("chapter.status.\(chapter.index)")
                    }
                    .width(min: 140, ideal: 170)
                }
            }
            .padding(20)
        }
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
                .accessibilityIdentifier("model.row.\(model.id)")
            }
        }
    }
}

private struct ModelDetailView: View {
    let model: TTSModelSnapshot
    @Bindable var store: LibraryPresentationStore
    @State private var voiceSearch = ""

    private var manifest: DownloadableModelManifest? {
        TTSModelCatalog.manifestsByID[model.id]
    }

    private var isPlatformCompatible: Bool {
        store.isPlatformCompatible(modelID: model.id)
    }

    private var filteredVoices: [TTSVoiceDescriptor] {
        voiceSearch.isEmpty ? model.voices : model.voices.filter {
            $0.displayName.localizedStandardContains(voiceSearch) || $0.id.localizedStandardContains(voiceSearch)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("模型", value: model.name)
                LabeledContent("标识", value: model.id)
                LabeledContent("框架", value: model.framework)
                LabeledContent("运行时", value: model.runtimeStatus)
                LabeledContent("支持语言", value: model.languages)
                LabeledContent("版本", value: model.version)
            } header: {
                Label("模型信息", systemImage: "waveform")
            }
            Section("默认模型") {
                if model.isDefault {
                    Label("当前默认模型", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if model.isAvailable {
                    Button("设为默认") { store.makeSelectedModelDefault() }
                } else {
                    Text("安装并验证模型后即可设为默认")
                        .foregroundStyle(.secondary)
                }
            }
            if manifest != nil {
                Section("模型文件") {
                    if !isPlatformCompatible {
                        Label("需要原生 Apple Silicon、macOS 15 或更高版本及 Metal", systemImage: "apple.logo")
                            .foregroundStyle(.secondary)
                    } else if model.installation == .downloading || model.installation == .verifying || model.installation == .installing {
                        ProgressView(value: model.downloadProgress) {
                            Text(model.runtimeStatus)
                        } currentValueLabel: {
                            Text(model.downloadProgress, format: .percent.precision(.fractionLength(0)))
                        }
                        Button("取消", role: .cancel) { store.cancelModelInstall() }
                    } else if model.installation == .installed {
                        Label("已安装到 Application Support", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        if let bytes = model.downloadSize {
                            Text("下载大小：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))。模型不会编译进 App。")
                                .foregroundStyle(.secondary)
                        }
                        Button(model.installation == .failed || model.installation == .corrupted ? "重新下载" : "下载模型") {
                            store.installSelectedModel()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("model.download")
                        if let failure = model.failureMessage { Text(failure).foregroundStyle(.red) }
                    }
                }
            }
            if model.isAvailable && !model.voices.isEmpty {
                Section("音色") {
                    TextField("搜索音色", text: $voiceSearch)
                        .accessibilityIdentifier("voice.search")
                    Picker("选择音色", selection: Binding(
                        get: { model.selectedVoiceID ?? model.voices[0].id },
                        set: { store.selectVoice($0) }
                    )) {
                        ForEach(filteredVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .accessibilityIdentifier("voice.picker")
                    Button(store.isPreviewing ? "停止试听" : "试听音色", systemImage: store.isPreviewing ? "stop.fill" : "play.fill") {
                        store.toggleVoicePreview()
                    }
                    .accessibilityIdentifier("voice.preview")
                    .disabled(store.activeCount > 0)
                    if store.activeCount > 0 {
                        Text("正式转换正在使用语音运行时，完成或暂停后可试听。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.importErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("voice.preview.error")
                    }
                }
            } else if model.id == TTSModelCatalog.systemID {
                Section("语音参数") {
                    Text("Apple 系统语音会根据书籍语言使用 macOS 中已安装的音色。")
                        .foregroundStyle(.secondary)
                }
            }
            Section("许可") {
                if model.id == TTSModelCatalog.kokoroID {
                    Link("sherpa-onnx · Apache-2.0", destination: URL(string: "https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.2/LICENSE")!)
                    Link("ONNX Runtime · MIT", destination: URL(string: "https://github.com/microsoft/onnxruntime/blob/v1.24.4/LICENSE")!)
                    Link("Kokoro 模型与随包资源许可", destination: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models")!)
                    if model.installation == .installed {
                        Button("打开已安装模型的 LICENSE") { store.openSelectedModelLicense() }
                    }
                } else if let manifest {
                    Link("\(model.name) · \(manifest.licenseIdentifier)", destination: manifest.sourceURL)
                    Link("speech-swift · Apache-2.0", destination: URL(string: "https://github.com/soniqo/speech-swift/blob/v0.0.23/LICENSE")!)
                    Link("MLX Swift · MIT", destination: URL(string: "https://github.com/ml-explore/mlx-swift/blob/0.31.6/LICENSE")!)
                }
            }
        }
        .formStyle(.grouped)
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

private struct ExportProgressDialog: View {
    @Bindable var store: LibraryPresentationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("正在导出有声书", systemImage: "square.and.arrow.up")
                .font(.headline)

            if let currentFile = store.exportCurrentFile {
                Text(currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(value: store.exportProgress)
                .accessibilityLabel("导出进度")
                .accessibilityValue(store.exportProgress.formatted(.percent))

            HStack {
                Text(store.exportProgress, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("取消导出", role: .cancel) {
                    store.cancelExport()
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("export.progressDialog")
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
