import SwiftUI

/// Top-level router. Shows the main split view (Dashboard + Mortgages) once
/// loaded; connecting a real account happens in a sheet.
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.phase == .loading {
                ProgressView("Loading…").controlSize(.large)
            } else {
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.phase)
        .sheet(isPresented: $state.showingConnectSheet) {
            OnboardingView()
        }
    }
}
