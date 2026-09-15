//
//  ModelStatusView.swift
//  abm
//
//  模型与引擎中心：现代化引擎主控仪表卡 + 本地模型资产管理 + 架构技术指标 + 快速目录导航。
//

import AppKit
import SwiftUI

struct ModelStatusView: View {
    let store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerArea

                engineHeroCard

                modelAssetCard

                specsSection

                quickAccessSection
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.checkModelCache() }
    }

    // MARK: - 顶部标题与快速检查

    private var headerArea: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型与引擎")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)
                Text("CosyVoice3 端侧大语言语音模型 · 基于 Apple Silicon MLX 硬件加速与离线推理")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    store.checkModelCache()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                    Text("刷新状态")
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 核心引擎主控仪表卡

    private var engineHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                // 状态动态图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(engineIconBackground)
                        .frame(width: 46, height: 46)

                    if store.isInitializing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: engineIconName)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: engineGlowColor.opacity(0.25), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("语音合成推理引擎")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)

                        engineStateBadge
                    }

                    Text(engineStateDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 右侧主操作按钮
                engineActionButton
            }

            // 加载进度条（初始化中平滑展示）
            if let progress = store.loadProgress {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress)
                        .tint(Color.orange)
                    HStack {
                        Text("正在加载权重到统一内存并构建计算图...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            if case .failed = store.engineState,
               case .missing = store.modelDownloadState {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text("本地缺少模型文件，请先在下方完成模型下载")
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .padding(.top, 2)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(engineCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(engineCardBorder, lineWidth: 1)
        )
        .shadow(color: engineGlowColor.opacity(0.08), radius: 6, y: 2)
    }

    private var engineIconName: String {
        switch store.engineState {
        case .ready: return "checkmark.circle.fill"
        case .loading: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .uninitialized: return "cpu.fill"
        }
    }

    private var engineIconBackground: LinearGradient {
        switch store.engineState {
        case .ready:
            return LinearGradient(colors: [Color(red: 0.10, green: 0.72, blue: 0.50), Color(red: 0.05, green: 0.52, blue: 0.35)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .loading:
            return LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.15), Color(red: 0.85, green: 0.38, blue: 0.08)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .failed:
            return LinearGradient(colors: [Color(red: 0.95, green: 0.32, blue: 0.32), Color(red: 0.80, green: 0.15, blue: 0.15)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .uninitialized:
            return LinearGradient(colors: [Color(red: 0.40, green: 0.45, blue: 0.55), Color(red: 0.28, green: 0.32, blue: 0.42)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var engineGlowColor: Color {
        switch store.engineState {
        case .ready: return .green
        case .loading: return .orange
        case .failed: return .red
        case .uninitialized: return .clear
        }
    }

    private var engineCardBackground: Color {
        switch store.engineState {
        case .ready: return Color.green.opacity(0.035)
        case .loading: return Color.orange.opacity(0.035)
        case .failed: return Color.red.opacity(0.035)
        case .uninitialized: return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var engineCardBorder: Color {
        switch store.engineState {
        case .ready: return Color.green.opacity(0.28)
        case .loading: return Color.orange.opacity(0.28)
        case .failed: return Color.red.opacity(0.28)
        case .uninitialized: return Color.primary.opacity(0.07)
        }
    }

    private var engineStateDescription: String {
        switch store.engineState {
        case .ready:
            return "本地端侧引擎运行中 · 驻留统一内存 · 随时就绪离线合成"
        case .loading(_, let message):
            return message
        case .failed(let msg):
            return "初始化异常: \(msg)，请检查模型文件或重试"
        case .uninitialized:
            return "模型权重已在本地就绪，点击初始化可将模型预载入显存"
        }
    }

    private var isEngineFailed: Bool {
        if case .failed = store.engineState { return true }
        return false
    }

    private var isCheckingCache: Bool {
        if case .checking = store.modelDownloadState { return true }
        return false
    }

    private var engineStateBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(engineBadgeColor)
                .frame(width: 6, height: 6)
            Text(engineBadgeText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(engineBadgeColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(
            Capsule()
                .fill(engineBadgeColor.opacity(0.12))
        )
    }

    private var engineBadgeText: String {
        switch store.engineState {
        case .ready: return "就绪 (在线)"
        case .loading: return "加载中"
        case .failed: return "出错"
        case .uninitialized: return "离线就绪"
        }
    }

    private var engineBadgeColor: Color {
        switch store.engineState {
        case .ready: return .green
        case .loading: return .orange
        case .failed: return .red
        case .uninitialized: return .secondary
        }
    }

    @ViewBuilder
    private var engineActionButton: some View {
        switch store.engineState {
        case .ready:
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("引擎已就绪")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Color.green))
                .foregroundStyle(.white)

                Button("重载") {
                    store.initializeEngine()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                )
                .foregroundStyle(.secondary)
            }

        case .loading:
            ProgressView()
                .controlSize(.small)

        case .uninitialized, .failed:
            Button {
                store.initializeEngine()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                    Text(isEngineFailed ? "重试初始化" : "初始化引擎")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: .command)
        }
    }

    // MARK: - 本地模型资产管理卡

    private var modelAssetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Fun-CosyVoice3-0.5B")
                            .font(.headline.weight(.semibold))

                        Text("MLX 8-bit 量化")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)

                        Text("约 2.0 GB")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)
                    }

                    Text("含多语言文本 Tokenizer、声学特征提取器与 Flow-Matching 声码器")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 下载/缓存状态标识与操作
                modelDownloadActionArea
            }

            // 下载进度展示
            if case .downloading(let progress, let message) = store.modelDownloadState {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress)
                        .tint(Color.accentColor)
                    HStack {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            // 缓存路径展示
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("缓存路径: ~/Library/Caches/qwen3-speech/models/\(SoniqoCosyVoiceEngine.modelID)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var modelDownloadActionArea: some View {
        switch store.modelDownloadState {
        case .cached:
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                    Text("本地缓存完整")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.green.opacity(0.12))
                )

                Button {
                    store.downloadModel()
                } label: {
                    Text("重新下载")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("下载中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .missing, .unknown, .checking:
            Button {
                store.downloadModel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                    Text(isCheckingCache ? "检查中…" : "下载模型 (约 2 GB)")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isCheckingCache)

        case .failed(let errorMsg):
            HStack(spacing: 8) {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)

                Button("重试下载") {
                    store.downloadModel()
                }
                .buttonStyle(RoundedRectProminentButtonStyle())
            }
        }
    }

    // MARK: - 架构技术规格网格（4 宫格展示）

    private var specsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("架构与规格")
                .font(.headline)
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: .infinity), spacing: 12)], spacing: 12) {
                specCard(
                    icon: "bolt.badge.automatic.fill",
                    iconColor: .orange,
                    title: "Apple Silicon MLX",
                    subtitle: "Metal 统一内存硬件加速 · 零网络离线推理"
                )
                specCard(
                    icon: "waveform.path.ecg",
                    iconColor: .purple,
                    title: "0.5B 双流自回归",
                    subtitle: "LLM 语义理解 + Flow-Matching 音频声码生成"
                )
                specCard(
                    icon: "speaker.wave.3.fill",
                    iconColor: .blue,
                    title: "24 kHz 高保真采样",
                    subtitle: "16-bit PCM 单声道广播级清晰人声品质"
                )
                specCard(
                    icon: "gauge.with.needle.fill",
                    iconColor: .green,
                    title: "实测 RTF ≈ 0.9",
                    subtitle: "生成 1 秒音频耗时小于 1 秒 · 高效批量产出"
                )
                starCard
            }
        }
    }

    /// 求 Star 卡片：点击跳转 GitHub 仓库
    private var starCard: some View {
        Button {
            if let url = URL(string: "https://github.com/shiye515/AudiobookMaker") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "star.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.yellow.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("求 Star 支持")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text("GitHub · shiye515/AudiobookMaker\n喜欢就点个 Star，助力持续迭代")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.yellow.opacity(0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在浏览器中打开 GitHub 仓库")
    }

    private func specCard(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 快速访问与目录导航

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("存储与快捷入口")
                .font(.headline)
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: .infinity), spacing: 12)], spacing: 12) {
                quickAccessCard(
                    icon: "books.vertical.fill",
                    title: "书籍目录",
                    description: "查看书籍项目数据与存储根目录",
                    action: { OutputManager.reveal(directory: AppPaths.logsDir.deletingLastPathComponent()) }
                )
                quickAccessCard(
                    icon: "square.and.arrow.up",
                    title: "导出目录",
                    description: "查看已导出的有声书与音频文件",
                    action: {
                        let dir = store.exportSettings.destinationDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        OutputManager.reveal(directory: dir)
                    }
                )
                quickAccessCard(
                    icon: "doc.text.magnifyingglass",
                    title: "系统运行日志",
                    description: "查看详细合成耗时、RTF 与诊断日志",
                    action: { OutputManager.reveal(directory: AppPaths.logsDir) }
                )
                quickAccessCard(
                    icon: "folder.fill",
                    title: "本地模型缓存",
                    description: "在访达中直接查看 HuggingFace 缓存文件",
                    action: { store.openModelDirectory() }
                )
            }
        }
    }

    private func quickAccessCard(icon: String, title: String, description: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
