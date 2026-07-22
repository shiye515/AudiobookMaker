import SwiftUI

struct SettingsView: View {
    @Bindable var store: LibraryPresentationStore
    @AppStorage("maxConcurrentJobs") private var maxConcurrentJobs = 1
    @AppStorage("keepIntermediatePCM") private var keepIntermediatePCM = false

    var body: some View {
        Form {
            Section("转换") {
                Picker("最大并发任务", selection: $maxConcurrentJobs) {
                    Text("1（推荐）").tag(1)
                    Text("2").tag(2)
                }
                Text("Kokoro 使用 CPU；CosyVoice3 与 Qwen3-TTS 需要原生 Apple Silicon 和 Metal。高内存本地模型会将安全并发限制为 1。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("默认模型") {
                Picker("模型", selection: Binding(
                    get: { store.models.first(where: \.isDefault)?.id ?? TTSModelCatalog.systemID },
                    set: { id in store.selectedModelID = id; store.makeSelectedModelDefault() }
                )) {
                    ForEach(store.models.filter(\.isAvailable)) { model in Text(model.name).tag(model.id) }
                }
                Text("可下载模型需在“模型”页面单独安装；所有权重都位于 App bundle 之外，合成时不会联网。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("文件") {
                Toggle("保留中间 PCM 文件", isOn: $keepIntermediatePCM)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 540, height: 380)
    }
}
