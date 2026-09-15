//
//  PlaybackBarView.swift
//  abm
//
//  主内容区底部悬浮播放条：展示当前播放内容名称与轻量进度（mm:ss / mm:ss + 底部细线进度条），
//  提供播放/暂停与停止控制；章节会话支持点击名称直达书籍详情页。
//  显隐绑定 AudioPlaybackService 的会话存在性（contextID != nil）：暂停保持可见，停止/播完/异常隐藏。
//

import SwiftUI

struct PlaybackBarView: View {
    let player: AudioPlaybackService
    let store: AppStore

    var body: some View {
        if player.contextID != nil {
            capsule
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 胶囊主体

    private var capsule: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                playPauseButton

                contentText

                if player.duration > 0 {
                    Text("\(timeString(player.currentTime)) / \(timeString(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                stopButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            progressBar
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
    }

    // MARK: - 控件

    private var playPauseButton: some View {
        Button {
            player.togglePause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "暂停" : "播放")
    }

    private var stopButton: some View {
        Button {
            player.stop()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("停止播放")
    }

    /// 内容名称：章节会话可点击直达书籍详情；音色会话静态展示
    @ViewBuilder
    private var contentText: some View {
        if let bookID = player.currentBookID {
            TitleSubtitleText(title: player.displayTitle ?? "正在播放",
                              subtitle: player.displaySubtitle,
                              isLink: true,
                              waveformActive: player.isPlaying)
                .contentShape(Rectangle())
                .onTapGesture { store.route = .bookDetail(bookID) }
                .help("打开书籍详情")
        } else {
            TitleSubtitleText(title: player.displayTitle ?? "正在播放",
                              subtitle: player.displaySubtitle,
                              isLink: false,
                              waveformActive: player.isPlaying)
        }
    }

    // MARK: - 进度与时间

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    /// 底部 2pt 细线进度条：浅色轨道 + 强调色已播段
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(2, geo.size.width * progressFraction))
            }
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.2), value: progressFraction)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 标题/副标题文本块

/// 章节会话下呈现为可点击形态（悬停下划线提示），音色会话为普通展示
private struct TitleSubtitleText: View {
    let title: String
    let subtitle: String?
    let isLink: Bool
    let waveformActive: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isLink && isHovering ? Color.accentColor : Color.primary)
                .underline(isLink && isHovering)
                .lineLimit(1)
            if let subtitle {
                HStack(spacing: 6) {
                    PlaybackWaveform(isActive: waveformActive)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 微动态波形指示

/// 播放中呈相位错开的律动，暂停时静止为低幅波形
private struct PlaybackWaveform: View {
    let isActive: Bool
    private let amplitudes: [CGFloat] = [0.55, 1.0, 0.7, 0.9, 0.6]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 2, height: 10)
                    .scaleEffect(y: isActive ? amplitudes[i] : 0.45)
                    .animation(
                        isActive
                            ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(Double(i) * 0.08)
                            : .easeInOut(duration: 0.15),
                        value: isActive
                    )
            }
        }
    }
}
