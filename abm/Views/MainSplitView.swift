//
//  MainSplitView.swift
//  abm
//
//  根视图：NavigationSplitView（侧边栏 + 主内容）+ 底部常驻播放条 + EPUB 拖拽导入。
//

import SwiftUI
import UniformTypeIdentifiers

struct MainSplitView: View {
    let store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isImporting = false
    @State private var draggedEPUBs: [URL] = []

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AppSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 120, ideal: 138, max: 160)
        } detail: {
            detailContent
                .frame(minWidth: 520)
                .safeAreaInset(edge: .bottom) {
                    PlaybackBarView(player: store.player, store: store)
                }
                // 避让边距伸缩与胶囊浮现/收起同频（弹簧）；空态下 inset 内容为空、不占位
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.player.contextID != nil)
        }
        .frame(minWidth: 660, minHeight: 600)
        .navigationTitle("讯音有声书")
        .toolbar {
            self.toolbarContent(isLibrary: isLibraryRoute)
        }
        .removeToolbarBezels(trigger: isLibraryRoute)
        .buttonStyle(RoundedRectButtonStyle())
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.importEPUBs(urls: urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
            guard !epubs.isEmpty else { return false }
            store.importEPUBs(urls: epubs)
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .abmImportEPUB)) { _ in
            isImporting = true
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.route {
        case .library:
            LibraryGridView(store: store)
        case .bookDetail(let bookID):
            BookDetailView(bookID: bookID, store: store)
        case .quickTTS:
            QuickTTSView(store: store)
        case .voiceCenter:
            VoiceLibraryView(store: store, player: store.player)
        case .model:
            ModelStatusView(store: store)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(isLibrary: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if isLibrary {
                HStack(spacing: 8) {
                    Button {
                        isImporting = true
                    } label: {
                        Text("导入 EPUB").roundedRectChrome(prominent: true)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("搜索", text: Binding(
                            get: { store.searchText },
                            set: { store.searchText = $0 }))
                            .textFieldStyle(.plain)
                            .font(.callout)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.15))
                    )
                    .frame(width: 170)
                }
                .padding(.trailing, 16)
            }
        }
    }

    private var isLibraryRoute: Bool {
        if case .library = store.route { return true }
        return false
    }
}
