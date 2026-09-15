//
//  QuickTTSView.swift
//  abm
//
//  快速单文本合成工坊：现代工作台布局 + 专属音色卡片与即时试听 + 沉浸式文本工坊 + 快捷键合成 + 成果即时试听与访达定位。
//

import SwiftUI

struct QuickTTSView: View {
    @Bindable var store: AppStore
    @FocusState private var isEditorFocused: Bool

    // 经典有声书试音样本文本
    private let sampleTexts: [(name: String, text: String)] = [
        ("散文诗歌", "月光洒在泛黄的纸页上，诗句化作溪流，在耳畔蜿蜒。听徐志摩的柔情在康桥泛起涟漪，让海子的麦浪与陶渊明的南山，在声音的褶皱里悄然生长。"),
        ("经典评书", "燕子去了，有再来的时候；杨柳枯了，有再青的时候；桃花谢了，有再开的时候。但是，聪明的，你告诉我，我们的日子为什么一去不复返呢？"),
        ("玄幻传奇", "他刚避开三头灵兽的围攻，转身就在峡谷深处发现了传说中的赤血金矿。那矿石在暗处泛着红光，看得人眼睛发直。矿洞深处突然传来一声咆哮，沉睡百年的紫金巨兽已然苏醒！")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerArea

                voiceSelectorCard

                textEditorCard

                actionControlBar

                if store.quickLastOutput != nil || store.quickHint != nil {
                    outputCard
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            ensureDefaultVoiceSelected()
        }
    }

    // MARK: - 顶部标题区

    private var headerArea: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("快速单文本")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)
                Text("即时输入或粘贴任意文本，选择专属有声书声线，一键生成高保真音频")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // 引擎就绪指示灯徽章
            engineStatusPill
        }
    }

    private var engineStatusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(engineColor)
                .frame(width: 7, height: 7)

            Text(store.isReady ? "引擎已就绪" : (store.isInitializing ? "初始化中…" : "引擎未就绪"))
                .font(.caption.weight(.medium))
                .foregroundStyle(engineColor)

            if !store.isReady && !store.isInitializing {
                Button("启动") {
                    store.initializeEngine()
                }
                .buttonStyle(.plain)
                .font(.caption.bold())
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(engineColor.opacity(0.1))
        )
    }

    private var engineColor: Color {
        if store.isReady { return .green }
        if store.isInitializing { return .orange }
        return .secondary
    }

    // MARK: - 音色选择与即时试听卡片

    private var voiceSelectorCard: some View {
        let currentVoice = selectedVoice

        return HStack(spacing: 14) {
            // 当前选中音色头像
            if let voice = currentVoice {
                ZStack {
                    Circle()
                        .fill(avatarGradient(for: voice.name, isMale: voice.trait.contains("男")))
                        .frame(width: 42, height: 42)
                    Image(systemName: avatarIcon(for: voice.name))
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }

            // 音色选择菜单与描述
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("合成音色")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let voice = currentVoice, voice.name == store.voiceLibrary.defaultNarratorName {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("默认旁白")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    }
                }

                Menu {
                    ForEach(store.voiceLibrary.voices) { voice in
                        Button {
                            store.quickVoiceID = voice.id
                        } label: {
                            HStack {
                                Text("\(voice.name) · \(voice.trait)")
                                if voice.id == store.quickVoiceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentVoice.map { "\($0.name) · \($0.trait)" } ?? "选择合成音色…")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            // 试听当前音色样本
            if let voice = currentVoice {
                Button {
                    previewVoice(voice)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isPreviewingCurrentVoice ? "stop.fill" : "play.fill")
                            .font(.system(size: 10))
                        Text(isPreviewingCurrentVoice ? "停止试听" : "试听样本 (10s)")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(isPreviewingCurrentVoice ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    )
                    .foregroundStyle(isPreviewingCurrentVoice ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var isPreviewingCurrentVoice: Bool {
        guard let voice = selectedVoice else { return false }
        return store.player.contextID == "voice/\(voice.audioFile)" && store.player.isPlaying
    }

    private func previewVoice(_ voice: VoiceSample) {
        let ctx = "voice/\(voice.audioFile)"
        if store.player.contextID == ctx && store.player.isPlaying {
            store.player.stop()
        } else if let url = VoiceLibrary.audioURL(for: voice) {
            store.player.play(url: url, contextID: ctx, title: voice.name, subtitle: "试听样本")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard store.player.contextID == ctx else { return }
                store.player.stop()
            }
        }
    }

    // MARK: - 沉浸式文本工坊卡片

    private var textEditorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 工具条：预设样例 + 清空 + 字数统计
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "quote.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("填入名段试听:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(sampleTexts, id: \.name) { sample in
                    Button(sample.name) {
                        withAnimation(.snappy(duration: 0.2)) {
                            store.quickText = sample.text
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.05))
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !store.quickText.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            store.quickText = ""
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("清空")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }

                // 字数统计与预估时长
                HStack(spacing: 4) {
                    Text("\(store.quickText.count) 字")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if store.quickText.count > 0 {
                        Text("· 约 \(estimatedSeconds)s 音频")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.primary.opacity(0.04))
                )
            }

            // 文本编辑区域
            ZStack(alignment: .topLeading) {
                if store.quickText.isEmpty {
                    Text("在此处粘贴或输入要合成的文本内容...\n支持多段落与标点，CosyVoice3 将自动完成自然停顿与语调演绎。")
                        .font(.body)
                        .lineSpacing(4)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $store.quickText)
                    .font(.body)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .focused($isEditorFocused)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isEditorFocused ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var estimatedSeconds: String {
        let count = store.quickText.count
        let seconds = Double(count) / 4.5
        return String(format: "%.1f", max(1.0, seconds))
    }

    // MARK: - 合成控制栏

    private var actionControlBar: some View {
        HStack(spacing: 12) {
            Button {
                synthesizeAction()
            } label: {
                HStack(spacing: 6) {
                    if store.isQuickSynthesizing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("正在合成中…")
                            .font(.headline.weight(.medium))
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13))
                        Text("开始合成")
                            .font(.headline.weight(.medium))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canSynthesize ? Color.accentColor : Color.secondary.opacity(0.3))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSynthesize)
            .keyboardShortcut(.return, modifiers: .command)

            Text("快捷键 ⌘Return · 合成结果将自动以 24kHz WAV 保存到音频目录")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var canSynthesize: Bool {
        store.isReady && !store.isQuickSynthesizing && !store.quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func synthesizeAction() {
        guard canSynthesize else { return }
        store.quickSynthesize()
    }

    // MARK: - 产出结果卡片

    @ViewBuilder
    private var outputCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let output = store.quickLastOutput {
                    Text("最近产出: \(output)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }

                if let hint = store.quickHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(store.engineErrorMessage == nil ? Color.secondary : Color.red)
                }
            }

            Spacer()

            Button {
                let dir = store.exportSettings.destinationDirectory
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                OutputManager.reveal(directory: dir)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("在访达中打开")
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - 辅助方法

    private var selectedVoice: VoiceSample? {
        if let id = store.quickVoiceID, let match = store.voiceLibrary.voices.first(where: { $0.id == id }) {
            return match
        }
        let defaultName = store.voiceLibrary.defaultNarratorName
        if !defaultName.isEmpty, let match = store.voiceLibrary.voices.first(where: { $0.name == defaultName }) {
            return match
        }
        return store.voiceLibrary.voices.first
    }

    private func ensureDefaultVoiceSelected() {
        if store.quickVoiceID == nil {
            if let defaultVoice = selectedVoice {
                store.quickVoiceID = defaultVoice.id
            }
        }
    }

    private func avatarGradient(for name: String, isMale: Bool) -> LinearGradient {
        switch name {
        case "龙妙":
            return LinearGradient(colors: [Color(red: 0.95, green: 0.40, blue: 0.60), Color(red: 0.80, green: 0.20, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙三叔":
            return LinearGradient(colors: [Color(red: 0.25, green: 0.42, blue: 0.88), Color(red: 0.12, green: 0.22, blue: 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙媛":
            return LinearGradient(colors: [Color(red: 0.98, green: 0.50, blue: 0.45), Color(red: 0.90, green: 0.32, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙悦":
            return LinearGradient(colors: [Color(red: 0.58, green: 0.38, blue: 0.95), Color(red: 0.42, green: 0.18, blue: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙修":
            return LinearGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.10), Color(red: 0.82, green: 0.45, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙楠":
            return LinearGradient(colors: [Color(red: 0.05, green: 0.70, blue: 0.80), Color(red: 0.08, green: 0.45, blue: 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙婉君":
            return LinearGradient(colors: [Color(red: 0.92, green: 0.32, blue: 0.60), Color(red: 0.76, green: 0.12, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙逸尘":
            return LinearGradient(colors: [Color(red: 0.98, green: 0.48, blue: 0.15), Color(red: 0.78, green: 0.28, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙老伯":
            return LinearGradient(colors: [Color(red: 0.08, green: 0.70, blue: 0.52), Color(red: 0.04, green: 0.46, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "龙老姨":
            return LinearGradient(colors: [Color(red: 0.68, green: 0.52, blue: 0.95), Color(red: 0.50, green: 0.25, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return isMale
                ? LinearGradient(colors: [Color(red: 0.30, green: 0.50, blue: 0.90), Color(red: 0.18, green: 0.32, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                : LinearGradient(colors: [Color(red: 0.95, green: 0.48, blue: 0.62), Color(red: 0.82, green: 0.28, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func avatarIcon(for name: String) -> String {
        switch name {
        case "龙妙": return "quote.bubble.fill"
        case "龙三叔": return "book.pages.fill"
        case "龙媛": return "heart.text.square.fill"
        case "龙悦": return "sparkles"
        case "龙修": return "text.book.closed.fill"
        case "龙楠": return "safari.fill"
        case "龙婉君": return "leaf.fill"
        case "龙逸尘": return "bolt.fill"
        case "龙老伯": return "hourglass"
        case "龙老姨": return "cup.and.saucer.fill"
        default: return "person.fill"
        }
    }
}
