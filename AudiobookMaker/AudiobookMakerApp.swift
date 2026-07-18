//
//  AudiobookMakerApp.swift
//  AudiobookMaker
//
//  Created by shiye on 2026/7/18.
//

import SwiftUI
import SwiftData

@main
struct AudiobookMakerApp: App {
    private let dependencies: DependencyContainer
    private let defaultWindowSize: CGSize
    @State private var store: LibraryPresentationStore

    init() {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let isEndToEndUITest = arguments.contains("--uitest-e2e")
            let dependencies = try DependencyContainer(
                inMemory: isEndToEndUITest,
                rootOverride: isEndToEndUITest
                    ? FileManager.default.temporaryDirectory.appending(
                        path: "AudiobookMaker-UITest-\(ProcessInfo.processInfo.processIdentifier)",
                        directoryHint: .isDirectory
                    )
                    : nil,
                runtime: isEndToEndUITest ? MockTTSRuntimeClient() : nil
            )
            self.dependencies = dependencies
            if arguments.contains("--uitest-narrow-window") {
                self.defaultWindowSize = CGSize(width: 760, height: 600)
            } else if arguments.contains("--uitest-short-window") {
                self.defaultWindowSize = CGSize(width: 980, height: 600)
            } else {
                self.defaultWindowSize = CGSize(width: 1180, height: 760)
            }
            if arguments.contains("--uitest-populated-library") {
                _store = State(initialValue: LibraryPresentationStore(mode: .populated))
            } else {
                _store = State(initialValue: LibraryPresentationStore(dependencies: dependencies))
            }
        } catch {
            fatalError("Could not initialize AudiobookMaker: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .modelContainer(dependencies.modelContainer)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
        .modelContainer(dependencies.modelContainer)
    }
}
