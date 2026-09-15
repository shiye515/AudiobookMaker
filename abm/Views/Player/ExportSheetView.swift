//
//  ExportSheetView.swift
//  abm
//
//  导出有声书模态 Sheet：卡片式格式选择 / 封面与元数据 / 码率 / 输出路径 + 进度反馈。
//

import AppKit
import SwiftUI

struct ExportSheetView: View {
    let book: BookProject?
    let store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let book {
                // 1. 顶部书籍信息卡片
                ExportHeaderView(book: book)

                // 2. 格式选择卡片组（三列）
                VStack(alignment: .leading, spacing: 8) {
                    Text("导出格式")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        FormatCard(
                            format: .m4b,
                            selectedFormat: store.exportSettings.format,
                            icon: "headphones",
                            title: "M4B 单文件",
                            badge: "推荐",
                            subtitle: "内嵌章节标记与封面",
                            suitability: "兼容 Apple Books / 播客",
                            isDisabled: store.isExporting
                        ) {
                            store.exportSettings.format = .m4b
                        }

                        FormatCard(
                            format: .mp3,
                            selectedFormat: store.exportSettings.format,
                            icon: "square.stack.3d.up.fill",
                            title: "分章节 M4A",
                            badge: nil,
                            subtitle: "按章节拆分为独立文件",
                            suitability: "适配普通播放器与车机",
                            isDisabled: store.isExporting
                        ) {
                            store.exportSettings.format = .mp3
                        }

                        FormatCard(
                            format: .wav,
                            selectedFormat: store.exportSettings.format,
                            icon: "waveform",
                            title: "WAV 无损",
                            badge: nil,
                            subtitle: "24kHz PCM 原始音质",
                            suitability: "音频体积大 · 适于剪辑",
                            isDisabled: store.isExporting
                        ) {
                            store.exportSettings.format = .wav
                        }
                    }
                }

                // 3. 详细参数卡片（系统分组底色）
                VStack(spacing: 0) {
                    // 行 1：元数据与封面
                    HStack(spacing: 12) {
                        Image(systemName: "photo.badge.checkmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("嵌入封面与元数据")
                                .font(.body.weight(.medium))
                            Text(store.exportSettings.format == .wav
                                 ? "WAV 无损格式不支持内嵌封面与章节元数据"
                                 : "自动写入书名、作者、EPUB 封面及各章节标记")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { store.exportSettings.embedCoverAndMetadata },
                            set: { store.exportSettings.embedCoverAndMetadata = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(store.isExporting || store.exportSettings.format == .wav)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    if store.exportSettings.format != .wav {
                        Divider().padding(.leading, 50)

                        // 行 2：音频码率
                        HStack(spacing: 12) {
                            Image(systemName: "speedometer")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("音频码率 (AAC)")
                                    .font(.body.weight(.medium))
                                Text("针对 24kHz 单声道优化，兼顾清晰人声与精简体积")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: Binding(
                                get: { store.exportSettings.bitrateKbps },
                                set: { store.exportSettings.bitrateKbps = $0 }
                            )) {
                                Text("64 kbps (推荐)").tag(64)
                                Text("32 kbps").tag(32)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            .disabled(store.isExporting)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }

                    Divider().padding(.leading, 50)

                    // 行 3：保存位置
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("导出保存目录")
                                .font(.body.weight(.medium))
                            Text(store.exportSettings.destinationDirectory.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(store.exportSettings.destinationDirectory.path)
                        }

                        Spacer()

                        Button("更改…") {
                            chooseDestinationDirectory()
                        }
                        .buttonStyle(RoundedRectButtonStyle())
                        .disabled(store.isExporting)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // 4. 警告横幅（未完全生成章节时）
                if book.doneCount < book.chapters.count {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.body)
                        Text("全书共 \(book.chapters.count) 章，当前就绪 \(book.doneCount) 章。未生成的 \(book.chapters.count - book.doneCount) 章将跳过导出。")
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.85))
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                }

                // 5. 状态反馈区（进度条 / 成功横幅 / 错误提示）
                if store.isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在导出与转码…")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int(store.exportProgress * 100))%")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: store.exportProgress)
                            .tint(.accentColor)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                    )
                } else if let result = store.exportResultText {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导出完成")
                                .font(.callout.weight(.semibold))
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if let first = store.exportResultURLs.first {
                            Button {
                                store.revealExport(url: first)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                    Text("在访达中显示")
                                }
                            }
                            .buttonStyle(RoundedRectButtonStyle())
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green.opacity(0.25), lineWidth: 1)
                    )
                } else if let hint = store.exportHint {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.red)
                            .font(.body)
                        Text(hint)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.08))
                    )
                }

                // 6. 底部操作栏
                HStack(spacing: 12) {
                    if let first = store.exportResultURLs.first, !store.isExporting, store.exportResultText == nil {
                        Button {
                            store.revealExport(url: first)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text("定位导出文件")
                            }
                        }
                        .buttonStyle(RoundedRectButtonStyle())
                    }

                    Spacer()

                    if store.isExporting {
                        Button("停止导出") {
                            store.cancelExport()
                        }
                        .buttonStyle(RoundedRectButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    } else {
                        Button(store.exportResultText != nil ? "完成" : "取消") {
                            dismiss()
                        }
                        .buttonStyle(RoundedRectButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    }

                    Button {
                        store.runExport(book: book, settings: store.exportSettings)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(store.isExporting ? "导出中…" : (store.exportResultText != nil ? "重新导出" : "开始导出"))
                        }
                    }
                    .buttonStyle(RoundedRectProminentButtonStyle())
                    .disabled(store.isExporting || book.doneCount == 0)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            } else {
                Text("书籍不存在")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private func chooseDestinationDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "请选择有声书导出的保存目录"
        panel.directoryURL = store.exportSettings.destinationDirectory
        if panel.runModal() == .OK, let selectedURL = panel.url {
            store.exportSettings.destinationDirectory = selectedURL
        }
    }
}

// MARK: - 书籍头部信息卡片

private struct ExportHeaderView: View {
    let book: BookProject

    private var durationText: String? {
        let totalSeconds = book.chapters
            .filter { $0.status == .done }
            .compactMap { $0.durationSeconds }
            .reduce(0, +)
        guard totalSeconds > 0 else { return nil }
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        } else {
            return "\(max(1, minutes)) 分钟"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // 封面缩略图
            ZStack {
                if let coverURL = LibraryStore.coverURL(for: book),
                   let image = NSImage(contentsOf: coverURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Image(systemName: "book.closed.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                    )
                }
            }
            .frame(width: 48, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1.5)

            // 书籍基本信息
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("导出有声书")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )

                    Spacer()

                    // 就绪状态徽标
                    if book.isFinished {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("\(book.chapters.count) 章全部就绪")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.green.opacity(0.1))
                        )
                    } else {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("已就绪 \(book.doneCount)/\(book.chapters.count) 章")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.1))
                        )
                    }
                }

                Text("《\(book.title)》")
                    .font(.title3.bold())
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !book.author.isEmpty {
                        Text(book.author)
                    }
                    if let duration = durationText {
                        Text("·")
                        Text("音频时长约 \(duration)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 格式卡片选择子视图

private struct FormatCard: View {
    let format: ExportFormat
    let selectedFormat: ExportFormat
    let icon: String
    let title: String
    let badge: String?
    let subtitle: String
    let suitability: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    private var isSelected: Bool { format == selectedFormat }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    Spacer()

                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                    }

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(suitability)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.08)
                          : (isHovered ? Color.primary.opacity(0.04) : Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(isHovered ? 0.15 : 0.08),
                            lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}
