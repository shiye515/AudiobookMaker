//
//  AppSidebar.swift
//  abm
//
//  左侧系统边栏：书架筛选（全部/正在生成/已完成）+ 快速单文本 + 音色中心。
//  侧边栏选择（SidebarItem）与主内容路由（AppRoute）解耦：进入图书详情时
//  侧边栏保持当前筛选高亮。
//

import SwiftUI

enum SidebarItem: Hashable {
    case filter(LibraryFilter)
    case quickTTS
    case voiceCenter
    case model
}

struct AppSidebar: View {
    let store: AppStore
    @State private var selection: SidebarItem? = .filter(.all)

    private var statusColor: Color {
        switch store.engineState {
        case .uninitialized: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([LibraryFilter.all, .generating, .finished]) { filter in
                    NavigationLink(value: SidebarItem.filter(filter)) {
                        HStack {
                            Label(filter.displayName, systemImage: icon(for: filter))
                            Spacer()
                            if filter == .generating, store.generatingBookCount > 0 {
                                Text("\(store.generatingBookCount)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: SidebarItem.quickTTS) {
                    Label("快速单文本", systemImage: "bolt")
                }
                NavigationLink(value: SidebarItem.voiceCenter) {
                    Label("音色中心", systemImage: "mic")
                }
                NavigationLink(value: SidebarItem.model) {
                    HStack {
                        Label("模型", systemImage: "cpu")
                        Spacer()
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, newValue in
            switch newValue {
            case .filter(let filter):
                store.libraryFilter = filter
                store.route = .library
            case .quickTTS:
                store.route = .quickTTS
            case .voiceCenter:
                store.route = .voiceCenter
            case .model:
                store.route = .model
            case nil:
                break
            }
        }
    }

    private func icon(for filter: LibraryFilter) -> String {
        switch filter {
        case .all: return "books.vertical"
        case .generating: return "arrow.down.circle"
        case .finished: return "checkmark.circle"
        }
    }
}
