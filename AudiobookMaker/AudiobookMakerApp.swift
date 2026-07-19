//
//  AudiobookMakerApp.swift
//  AudiobookMaker
//
//  Created by shiye on 2026/7/18.
//

import AppKit
import SwiftData
import SwiftUI

final class AudiobookMakerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AudiobookMakerApp: App {
    @NSApplicationDelegateAdaptor(AudiobookMakerAppDelegate.self) private var appDelegate
    private let dependencies: DependencyContainer
    private let defaultWindowSize: CGSize
    @State private var store: LibraryPresentationStore

    init() {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let isEndToEndUITest = arguments.contains("--uitest-e2e")
            let usesIsolatedUITestData = arguments.contains { $0.hasPrefix("--uitest-") }
            let dependencies = try DependencyContainer(
                inMemory: usesIsolatedUITestData,
                rootOverride: usesIsolatedUITestData
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
            SettingsView(store: store)
        }
        .modelContainer(dependencies.modelContainer)
    }
}
