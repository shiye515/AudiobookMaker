import SwiftUI

struct SettingsView: View {
    @AppStorage("maxConcurrentJobs") private var maxConcurrentJobs = 1
    @AppStorage("selectedModelID") private var selectedModelID = "com.audiobookmaker.apple-system-speech"
    @AppStorage("keepIntermediatePCM") private var keepIntermediatePCM = false

    var body: some View {
        Form {
            Section("转换") {
                Picker("最大并发任务", selection: $maxConcurrentJobs) {
                    Text("1（推荐）").tag(1)
                    Text("2").tag(2)
                }
                Text("运行时可根据模型能力进一步降低并发数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("默认模型") {
                Picker("模型", selection: $selectedModelID) {
                    Text("Apple 系统语音").tag("com.audiobookmaker.apple-system-speech")
                    Text("CosyVoice3 0.5B（需要 Apple Silicon）")
                        .tag("aufklarer/CosyVoice3-0.5B-MLX-8bit-full")
                        .disabled(true)
                }
                Text("当前 Intel Mac 使用 AVFoundation 系统语音；CosyVoice 需要 Apple Silicon 运行时。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文件") {
                Toggle("保留中间 PCM 文件", isOn: $keepIntermediatePCM)
                Text("关闭时，验证成功后会清理中间音频文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 360)
    }
}
