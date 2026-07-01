import SwiftUI

@main
struct PhinnyApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 640)
                .task { await state.bootstrap() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Sync Now") { Task { await state.sync(force: true) } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
