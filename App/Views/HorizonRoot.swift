import SwiftUI

enum HorizonTab: Hashable { case live, review, recordings, search, exports, protectedMedia, administration, settings }

struct HorizonRoot: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @State private var selection: HorizonTab = .live

    var body: some View {
        TabView(selection: $selection) {
            Tab("Live", systemImage: "video", value: HorizonTab.live) {
                LiveView(api: api, active: selection == .live)
            }
            Tab("Review", systemImage: "rectangle.stack", value: HorizonTab.review) {
                ReviewView(api: api)
            }
            Tab("Recordings", systemImage: "clock.arrow.circlepath", value: HorizonTab.recordings) {
                RecordingsView(api: api)
            }
            Tab("Search", systemImage: "magnifyingglass", value: HorizonTab.search) {
                EventSearchView(api: api)
            }
            Tab("Exports", systemImage: "film.stack", value: HorizonTab.exports) {
                ExportsView(api: api, active: selection == .exports)
            }
            Tab("Protected", systemImage: "lock.shield", value: HorizonTab.protectedMedia) {
                ProtectedMediaView(api: api)
            }
            if model.isAdmin {
                Tab("Admin", systemImage: "server.rack", value: HorizonTab.administration) {
                    AdministrationView(api: api)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: HorizonTab.settings) {
                SettingsView(api: api)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(HorizonPalette.accent)
        .toolbarBackground(HorizonPalette.surface, for: .tabBar)
        .background { HorizonBackdrop() }
        .onChange(of: model.isAdmin) { _, isAdmin in
            if !isAdmin && selection == .administration { selection = .settings }
        }
        .onChange(of: push.route) { _, route in
            if route != nil { selection = .settings }
        }
    }
}
