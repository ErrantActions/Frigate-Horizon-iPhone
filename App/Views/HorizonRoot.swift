import SwiftUI
import HorizonCore

enum HorizonTab: Hashable { case live, review, recordings, search, exports, protectedMedia, administration, settings }

struct HorizonRoot: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @State private var selection: HorizonTab = .live
    @State private var restoredCamera: HorizonCamera?
    @ObservedObject private var pictureInPicture = LivePictureInPictureController.shared
    @ObservedObject private var talkbackCleanup = CameraTalkbackCleanupStore.shared

    var body: some View {
        TabView(selection: $selection) {
            Tab("Live", systemImage: "video", value: HorizonTab.live) {
                LiveView(api: api, active: selection == .live && restoredCamera == nil)
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
        .safeAreaInset(edge: .bottom) {
            if let error = pictureInPicture.error {
                VStack {
                    ErrorNotice(message: error)
                    Button("Dismiss message") { pictureInPicture.error = nil }
                }
                .padding().background(HorizonPalette.surface)
            } else if let error = talkbackCleanup.error {
                ErrorNotice(message: error).padding().background(HorizonPalette.surface)
            } else if talkbackCleanup.isPending, let status = talkbackCleanup.status {
                Text(status).font(.footnote).padding().background(HorizonPalette.surface)
            } else if let issue = model.connectionIssue {
                HStack(spacing: 12) {
                    Label(issue.title, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                    Spacer()
                    Button("Review connection") { selection = .settings }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .padding(.horizontal)
                .background(HorizonPalette.surface)
            }
        }
        .sheet(item: $restoredCamera) { camera in
            if let current = model.cameras.first(where: { $0.id == camera.id && $0.settings.enabled }) {
                CameraDetailView(api: api, camera: current)
            }
        }
        .onAppear {
            pictureInPicture.restoreUserInterface = { requested in
                guard model.api === api,
                      let camera = model.cameras.first(where: { $0.id == requested.cameraID && $0.settings.enabled }) else {
                    pictureInPicture.error = "The Picture in Picture camera is no longer available to this account."
                    pictureInPicture.stop()
                    return
                }
                let hls = pictureInPicture.retainedLiveHLSConfiguration(api: api, cameraID: camera.id) != nil
                guard hls ? camera.settings.ui?.liveHLS == true : camera.settings.live.streams.values.contains(requested.stream) else {
                    pictureInPicture.error = "The Picture in Picture playback source is no longer available."
                    pictureInPicture.stop()
                    return
                }
                UserDefaults.standard.set(requested.transport, forKey: "liveTransport")
                selection = .live
                restoredCamera = camera
            }
        }
        .onDisappear { pictureInPicture.restoreUserInterface = nil }
        .onChange(of: model.cameras.filter { $0.settings.enabled }.map(\.id)) { _, ids in
            if let restoredCamera, !ids.contains(restoredCamera.id) { self.restoredCamera = nil }
        }
        .onChange(of: model.isAdmin) { _, isAdmin in
            if !isAdmin && selection == .administration { selection = .settings }
        }
        .onChange(of: push.route) { _, route in
            if route != nil { restoredCamera = nil; selection = .settings }
        }
    }
}
