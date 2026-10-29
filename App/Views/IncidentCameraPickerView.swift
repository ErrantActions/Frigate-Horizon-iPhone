import SwiftUI
import HorizonCore

struct IncidentCameraPickerView: View {
    let api: HorizonAPI
    let cameras: [HorizonCamera]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var date: Date
    @State private var openWorkspace = false

    init(api: HorizonAPI, cameras: [HorizonCamera], initialDate: Date = Date().addingTimeInterval(-30)) {
        self.api = api
        self.cameras = cameras
        _selected = State(initialValue: Set(cameras.prefix(4).map(\.id)))
        _date = State(initialValue: initialDate)
    }

    private var selectedIDs: [String] { cameras.map(\.id).filter { selected.contains($0) } }

    var body: some View {
        if openWorkspace {
            IncidentWorkspaceView(api: api, cameraIDs: selectedIDs, initialDate: date)
        } else {
          NavigationStack {
            Form {
                Section {
                    HorizonHero(title: "See the whole incident",
                        subtitle: "Choose two to four camera angles and review their recordings against one shared clock.",
                        systemImage: "square.split.2x2", eyebrow: "Incident replay")
                        .horizonHeroRow()
                    DatePicker("Recording time", selection: $date, in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    ForEach(cameras) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { selected.contains(camera.id) },
                            set: { enabled in
                                if enabled && selected.count < 4 { selected.insert(camera.id) }
                                else if !enabled { selected.remove(camera.id) }
                            }
                        ))
                        .disabled(!selected.contains(camera.id) && selected.count >= 4)
                    }
                } header: {
                    Text("\(selectedIDs.count) of 4 selected")
                } footer: {
                    Text("Only cameras available to your current account and dashboard group are listed. Missing recordings stay visible as gaps; live video is never substituted.")
                }
                Button("Open synchronized replay", systemImage: "play.rectangle.on.rectangle") {
                    LivePictureInPictureController.shared.stop()
                    openWorkspace = true
                }
                .disabled(!(2...4).contains(selectedIDs.count))
            }
            .horizonScreen()
            .navigationTitle("Incident replay")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
          }
        }
    }
}
