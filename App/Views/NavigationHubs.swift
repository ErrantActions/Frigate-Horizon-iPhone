import SwiftUI
import HorizonCore

@MainActor
final class ActivityNavigationState: ObservableObject {
    @Published var mode: ActivityMode = .review
    @Published var reviewQuery = ReviewQuery()
    @Published var searchQuery = EventSearchQuery(
        after: Date().addingTimeInterval(-86400).timeIntervalSince1970,
        before: Date().timeIntervalSince1970)
    @Published var searchText = ""
}

struct ActivityView: View {
    let api: HorizonAPI
    @ObservedObject var state: ActivityNavigationState
    var forcedMode: ActivityMode? = nil

    var body: some View {
        Group {
            if (forcedMode ?? state.mode) == .review {
                ReviewView(api: api, query: $state.reviewQuery,
                    activityMode: forcedMode == nil ? $state.mode : nil)
            } else {
                EventSearchView(api: api, query: $state.searchQuery, text: $state.searchText,
                    activityMode: forcedMode == nil ? $state.mode : nil)
            }
        }
    }
}

struct ActivityModePicker: View {
    @Binding var selection: ActivityMode

    var body: some View {
        Picker("Activity view", selection: $selection) {
            Text("Activity").tag(ActivityMode.review)
            Text("Search").tag(ActivityMode.search)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
    }
}

struct LibraryView: View {
    let api: HorizonAPI
    let active: Bool
    @Binding var section: LibrarySection
    @Binding var camera: String

    var body: some View {
        Group {
            if section == .exports {
                ExportsView(api: api, active: active, camera: $camera, librarySection: $section)
            } else {
                ProtectedMediaView(api: api, camera: $camera, librarySection: $section)
            }
        }
    }
}

struct LibrarySectionPicker: View {
    @Binding var selection: LibrarySection

    var body: some View {
        Picker("Library", selection: $selection) {
            Text("Exports").tag(LibrarySection.exports)
            Text("Protected").tag(LibrarySection.protectedMedia)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
    }
}
