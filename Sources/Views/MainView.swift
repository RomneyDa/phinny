import SwiftUI

/// The main window: a sidebar (Dashboard + each mortgage) and a detail pane.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Nav? = .dashboard
    @State private var showingNewMortgage = false

    enum Nav: Hashable {
        case dashboard
        case categories
        case mortgage(String)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: Nav.dashboard) {
                    Label("Dashboard", systemImage: "chart.pie.fill")
                }
                NavigationLink(value: Nav.categories) {
                    Label("Categories", systemImage: "tag.fill")
                }
                Section("Mortgages") {
                    ForEach(state.mortgages) { m in
                        NavigationLink(value: Nav.mortgage(m.id)) {
                            Label(m.name.isEmpty ? "Mortgage" : m.name, systemImage: "house.fill")
                        }
                    }
                    Button {
                        showingNewMortgage = true
                    } label: {
                        Label("Add Mortgage", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 235, max: 300)
        } detail: {
            detail
        }
        .sheet(isPresented: $showingNewMortgage) {
            MortgageEditorView(draft: state.makeDraftMortgage(), isNew: true) { selection = .mortgage($0.id) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .dashboard {
        case .dashboard:
            DashboardView()
        case .categories:
            CategoriesView()
        case .mortgage(let id):
            if let m = state.mortgages.first(where: { $0.id == id }) {
                MortgageDetailView(mortgage: m)
                    .id(m.id)
            } else {
                ContentUnavailableView("Mortgage not found", systemImage: "house")
            }
        }
    }
}
