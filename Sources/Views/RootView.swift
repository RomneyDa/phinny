import SwiftUI

/// Top-level router. The dashboard is shown in both demo and connected modes;
/// connecting a real account happens in a sheet.
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.phase {
            case .loading:
                ProgressView("Loading…").controlSize(.large)
            case .demo, .ready:
                DashboardView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.phase)
        .sheet(isPresented: $state.showingConnectSheet) {
            OnboardingView()
        }
    }
}
