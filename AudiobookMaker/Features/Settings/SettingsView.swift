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
                Text("Kokoro 在 Intel 与 Apple 芯片上都使用 CPU 推理，并会将并发限制为 1。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("默认模型") {
                Picker("模型", selection: Binding(
                    get: { store.models.first(where: \.isDefault)?.id ?? TTSModelCatalog.systemID },
                    set: { id in store.selectedModelID = id; store.makeSelectedModelDefault() }
                )) {
                    ForEach(store.models.filter(\.isAvailable)) { model in Text(model.name).tag(model.id) }
                }
                Text("Kokoro 模型需在“模型”页面单独下载；权重不包含在 App 中。")
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
