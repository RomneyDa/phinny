import SwiftUI

@main
struct PhinnyApp: App {
    @StateObject private var state = AppState()

    init() {
        // Dev-only: `PHINNY_GENERATE_DEMO=<path> Phinny` writes the bundled
        // demo database (via the real DB code) and exits. See scripts/generate-demo-db.sh.
        if let path = ProcessInfo.processInfo.environment["PHINNY_GENERATE_DEMO"] {
            do {
                try DemoData.generate(to: URL(fileURLWithPath: path))
                print("Wrote demo database to \(path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Demo generation failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

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
