//
//  VoiceLibraryView.swift
//  abm
//
//  音色中心：流媒体风格现代卡片 + 专属声学艺术头像 + 动态跳动频谱试听 + 名著台词引用 + 胶囊分类筛选。
//

import SwiftUI

struct VoiceLibraryView: View {
    let store: AppStore
    let player: AudioPlaybackService
    @State private var category: VoiceLibrary.VoiceCategory = .all
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerArea

                if filteredVoices.isEmpty {
                    VoiceEmptyStateView {
                        category = .all
                        searchText = ""
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320, maximum: .infinity), spacing: 18)],
                        spacing: 18
                    ) {
                        ForEach(filteredVoices) { voice in
                            VoiceCardView(voice: voice, store: store, player: player)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    // MARK: - 顶部标题与筛选工具栏

    private var headerArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题区
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("音色中心")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("CosyVoice3 精选 10 款有声书专属声线，支持试听采样与设为全局默认旁白")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // 分类 Pills 与搜索输入框
            HStack(spacing: 12) {
                CategoryPillBar(selected: $category, store: store)

                Spacer()

                VoiceSearchBar(text: $searchText)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private var filteredVoices: [VoiceSample] {
        store.voiceLibrary.voices.filter { voice in
            let categoryOK = category == .all || store.voiceLibrary.categories(for: voice).contains(category)
            let keyword = searchText.trimmingCharacters(in: .whitespaces)
            let searchOK = keyword.isEmpty
                || voice.name.localizedCaseInsensitiveContains(keyword)
                || voice.trait.localizedCaseInsensitiveContains(keyword)
                || voice.text.localizedCaseInsensitiveContains(keyword)
                || store.voiceLibrary.genre(for: voice).localizedCaseInsensitiveContains(keyword)
            return categoryOK && searchOK
        }
    }
}

// MARK: - 分类胶囊选择栏

private struct CategoryPillBar: View {
    @Binding var selected: VoiceLibrary.VoiceCategory
    let store: AppStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(VoiceLibrary.VoiceCategory.allCases) { cat in
                let isSelected = selected == cat
                let count = store.voiceLibrary.count(for: cat)

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selected = cat
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(cat.rawValue)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))

                        Text("\(count)")
                            .font(.caption2.weight(isSelected ? .bold : .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - 搜索输入框

private struct VoiceSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("搜索音色、特质或台词...", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 220)
    }
}

// MARK: - 音色卡片

struct VoiceCardView: View {
    let voice: VoiceSample
    let store: AppStore
    let player: AudioPlaybackService

    @State private var isHovered = false
    /// 当前试听的 10 秒倒计时句柄：新试听启动时先取消旧倒计时，防止竞态误杀新音频
    @State private var previewTask: Task<Void, Never>?

    private var isDefault: Bool {
        store.voiceLibrary.defaultNarratorName == voice.name
    }
    private var previewContextID: String { "voice/\(voice.audioFile)" }
    private var isPlayingThis: Bool { player.contextID == previewContextID && player.isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部：专属声学艺术头像 + 姓名/年龄标签 + 题材 + 右上角默认标识
            HStack(alignment: .center, spacing: 12) {
                VoiceAvatarView(voice: voice, isPlaying: isPlayingThis)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(voice.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let age = voice.age {
                            Text(age)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(voice.trait)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(store.voiceLibrary.genre(for: voice))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                // 右上角默认状态/设为默认操作（取代旧设计中喧宾夺主的全宽大蓝条）
                VStack {
                    if isDefault {
                        HStack(spacing: 3.5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("默认旁白")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .shadow(color: Color.accentColor.opacity(0.22), radius: 3, y: 1)
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                store.setDefaultNarrator(voice.name)
                            }
                        } label: {
                            HStack(spacing: 3.5) {
                                Image(systemName: "star")
                                    .font(.system(size: 9.5))
                                Text("设为默认")
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.10), lineWidth: 0.8)
                            )
                            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            // 中部：典雅的名著采样台词展示框
            VoiceQuoteBox(text: voice.text)

            // 底部：现代化一体试听控制条（动态跳动频谱 + 播放/停止交互）
            VoicePreviewBar(isPlaying: isPlayingThis) {
                togglePlayback()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDefault ? Color.accentColor.opacity(0.03) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDefault
                        ? Color.accentColor.opacity(0.32)
                        : (isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.07)),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isDefault
                ? Color.accentColor.opacity(0.12)
                : (isHovered ? Color.black.opacity(0.06) : Color.clear),
            radius: isDefault ? 8 : (isHovered ? 6 : 2),
            y: isDefault ? 2 : (isHovered ? 2 : 1)
        )
        .offset(y: isHovered ? -2 : 0)
        .animation(.snappy(duration: 0.2), value: isHovered)
        .animation(.snappy(duration: 0.25), value: isDefault)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func togglePlayback() {
        if isPlayingThis {
            player.stop()
        } else if let url = VoiceLibrary.audioURL(for: voice) {
            player.play(url: url, contextID: previewContextID, title: voice.name, subtitle: "试听样本")
            // 样本最长试听 10 秒，到点自动结束会话（避免播放条悬挂）
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, player.contextID == previewContextID else { return }
                player.stop()
            }
        }
    }
}

// MARK: - 专属声学艺术头像

private struct VoiceAvatarView: View {
    let voice: VoiceSample
    let isPlaying: Bool
    @State private var pulseWave = false

    var body: some View {
        let theme = avatarTheme(for: voice)

        ZStack {
            // 播放中的动态扩散呼吸光晕环
            if isPlaying {
                Circle()
                    .stroke(theme.gradient[0].opacity(pulseWave ? 0.0 : 0.5), lineWidth: pulseWave ? 4 : 1.5)
                    .frame(width: 46, height: 46)
                    .scaleEffect(pulseWave ? 1.32 : 1.0)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulseWave)
            }

            // 头像渐变底
            Circle()
                .fill(
                    LinearGradient(
                        colors: theme.gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .shadow(color: theme.gradient[0].opacity(0.25), radius: 3, y: 1.5)

            // 声学/文学专属图腾
            Image(systemName: theme.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: 52, height: 52)
        .onAppear {
            if isPlaying { pulseWave = true }
        }
        .onChange(of: isPlaying) { _, playing in
            pulseWave = playing
        }
    }

    private struct AvatarTheme {
        let gradient: [Color]
        let icon: String
    }

    private func avatarTheme(for voice: VoiceSample) -> AvatarTheme {
        switch voice.name {
        case "龙妙":
            return AvatarTheme(
                gradient: [Color(red: 0.95, green: 0.40, blue: 0.60), Color(red: 0.80, green: 0.20, blue: 0.45)],
                icon: "quote.bubble.fill"
            )
        case "龙三叔":
            return AvatarTheme(
                gradient: [Color(red: 0.25, green: 0.42, blue: 0.88), Color(red: 0.12, green: 0.22, blue: 0.58)],
                icon: "book.pages.fill"
            )
        case "龙媛":
            return AvatarTheme(
                gradient: [Color(red: 0.98, green: 0.50, blue: 0.45), Color(red: 0.90, green: 0.32, blue: 0.18)],
                icon: "heart.text.square.fill"
            )
        case "龙悦":
            return AvatarTheme(
                gradient: [Color(red: 0.58, green: 0.38, blue: 0.95), Color(red: 0.42, green: 0.18, blue: 0.82)],
                icon: "sparkles"
            )
        case "龙修":
            return AvatarTheme(
                gradient: [Color(red: 0.95, green: 0.62, blue: 0.10), Color(red: 0.82, green: 0.45, blue: 0.05)],
                icon: "text.book.closed.fill"
            )
        case "龙楠":
            return AvatarTheme(
                gradient: [Color(red: 0.05, green: 0.70, blue: 0.80), Color(red: 0.08, green: 0.45, blue: 0.58)],
                icon: "safari.fill"
            )
        case "龙婉君":
            return AvatarTheme(
                gradient: [Color(red: 0.92, green: 0.32, blue: 0.60), Color(red: 0.76, green: 0.12, blue: 0.38)],
                icon: "leaf.fill"
            )
        case "龙逸尘":
            return AvatarTheme(
                gradient: [Color(red: 0.98, green: 0.48, blue: 0.15), Color(red: 0.78, green: 0.28, blue: 0.08)],
                icon: "bolt.fill"
            )
        case "龙老伯":
            return AvatarTheme(
                gradient: [Color(red: 0.08, green: 0.70, blue: 0.52), Color(red: 0.04, green: 0.46, blue: 0.35)],
                icon: "hourglass"
            )
        case "龙老姨":
            return AvatarTheme(
                gradient: [Color(red: 0.68, green: 0.52, blue: 0.95), Color(red: 0.50, green: 0.25, blue: 0.88)],
                icon: "cup.and.saucer.fill"
            )
        default:
            let isMale = voice.trait.contains("男")
            return AvatarTheme(
                gradient: isMale
                    ? [Color(red: 0.30, green: 0.50, blue: 0.90), Color(red: 0.18, green: 0.32, blue: 0.72)]
                    : [Color(red: 0.95, green: 0.48, blue: 0.62), Color(red: 0.82, green: 0.28, blue: 0.48)],
                icon: isMale ? "person.crop.circle" : "person.crop.circle.fill"
            )
        }
    }
}

// MARK: - 名著采样台词引用框

private struct VoiceQuoteBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .padding(.top, 2)

            Text(text)
                .font(.callout)
                .lineSpacing(2.5)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - 动态跳动频谱波形组件

private struct AnimatedSpectrumWaveform: View {
    let isPlaying: Bool
    @State private var phase = false

    private let baseHeights: [CGFloat] = [5, 9, 13, 17, 14, 11, 8, 6, 4]
    private let bounceScales: [CGFloat] = [1.4, 0.4, 1.3, 0.5, 1.3, 0.6, 1.2, 0.5, 1.4]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<9, id: \.self) { i in
                Capsule()
                    .fill(isPlaying ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(
                        width: 2.5,
                        height: isPlaying
                            ? max(3, baseHeights[i] * (phase ? bounceScales[i] : (2.0 - bounceScales[i])))
                            : baseHeights[i]
                    )
            }
        }
        .frame(height: 20)
        .onAppear {
            if isPlaying { startAnimation() }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startAnimation()
            } else {
                phase = false
            }
        }
    }

    private func startAnimation() {
        withAnimation(.easeInOut(duration: 0.38).repeatForever(autoreverses: true)) {
            phase = true
        }
    }
}

// MARK: - 一体化试听控制条

private struct VoicePreviewBar: View {
    let isPlaying: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                // 圆形播放/停止指示
                ZStack {
                    Circle()
                        .fill(isPlaying ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 26, height: 26)

                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isPlaying ? Color.white : Color.primary)
                        .offset(x: isPlaying ? 0 : 0.5)
                }

                AnimatedSpectrumWaveform(isPlaying: isPlaying)

                Spacer()

                HStack(spacing: 4) {
                    if isPlaying {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                        Text("试听中 · 10s")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text("试听 10s 样本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPlaying ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isPlaying ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 搜索/筛选空状态

private struct VoiceEmptyStateView: View {
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.6))

            Text("未找到匹配的音色")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("尝试更换搜索关键词或切换上方题材分类")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button("清空筛选与搜索", action: onReset)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}
