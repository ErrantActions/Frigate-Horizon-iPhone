import SwiftUI
import AVKit
import HorizonCore

@MainActor
final class RecordingPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var error: String?
    @Published private(set) var loading = true
    @Published private(set) var position = 0.0
    @Published private(set) var isSeeking = false
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var initialPosition = 0.0
    private var seekGeneration = UUID()

    func open(url: URL, api: HorizonAPI, initialPosition: Double = 0, autoplay: Bool = true) {
        stop()
        loading = true
        error = nil
        self.initialPosition = initialPosition
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: api.cookies])
            let item = AVPlayerItem(asset: asset)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.loading = false
                        self.seek(to: self.initialPosition, autoplay: autoplay)
                    case .failed:
                        self.loading = false
                        self.error = item.error?.localizedDescription ?? "Recording playback failed."
                    default: break
                    }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription ?? "The recording stopped unexpectedly."
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    self.error = message
                    self.loading = false
                }
            }
            player.replaceCurrentItem(with: item)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item, time.seconds.isFinite else { return }
                    self.position = time.seconds
                }
            }
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    func stop() {
        seekGeneration = UUID()
        isSeeking = false
        loading = false
        error = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.replaceCurrentItem(with: nil)
        position = 0
    }

    func seek(to position: Double, autoplay: Bool? = nil) {
        guard position.isFinite, position >= 0 else {
            error = "The selected recording position is invalid."
            return
        }
        guard let item = player.currentItem else {
            error = "No recording is loaded for seeking."
            return
        }
        let token = UUID()
        seekGeneration = token
        isSeeking = true
        if autoplay == false { player.pause() }
        player.seek(to: CMTime(seconds: position, preferredTimescale: 90000),
            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                Task { @MainActor in
                    guard let self, self.seekGeneration == token, self.player.currentItem === item else { return }
                    self.isSeeking = false
                    if completed && autoplay == true { self.player.play() }
                }
            }
    }
}

struct NativeRecordingSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

struct RecordingPlaybackView: View {
    let api: HorizonAPI
    let camera: String
    let start: Double
    let end: Double
    @StateObject private var playback = RecordingPlayer()
    @State private var retry = 0
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if expanded { Color.black }
                else { NativeRecordingSurface(player: playback.player) }
            }
                .background(.black)
                .overlay {
                    if playback.loading { ProgressView("Opening recording").tint(.white).foregroundStyle(.white) }
                }
                .frame(minHeight: 180)
            if let error = playback.error {
                ErrorNotice(message: error) { retry += 1 }
            }
            HStack {
                Label("Recorded", systemImage: "clock")
                Spacer()
                Button("Expand player", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        }
        .task(id: "\(camera)-\(start)-\(end)-\(retry)") {
            addressError = nil
            do {
                let url = try api.address.playback(camera: camera, start: start, end: end)
                playback.open(url: url, api: api)
            } catch {
                playback.stop()
                addressError = error.localizedDescription
            }
        }
        .overlay(alignment: .bottom) {
            if let addressError { ErrorNotice(message: addressError) { retry += 1 } }
        }
        .fullScreenCover(isPresented: $expanded) {
            FoldedRecordingView(player: playback.player, start: start)
        }
        .onDisappear { if !expanded { playback.stop() } }
    }

    @State private var addressError: String?
}

private struct FoldedRecordingView: View {
    let player: AVPlayer
    let start: Double
    @Environment(\.dismiss) private var dismiss
    @State private var foldMode: FoldMode = .flat
    @State private var playing = true

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                NativeRecordingSurface(player: player)
                    .background(.black)
            } secondary: {
                VStack(spacing: 24) {
                    Label(foldMode.title, systemImage: foldMode == .book ? "book" : "play.rectangle")
                        .font(.headline)
                    Text(Date(timeIntervalSince1970: start), format: .dateTime)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 32) {
                        Button("Back 15 seconds", systemImage: "gobackward.15") { skip(-15) }
                        Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                            if player.rate == 0 { player.play() } else { player.pause() }
                            playing = player.rate != 0
                        }
                        Button("Forward 15 seconds", systemImage: "goforward.15") { skip(15) }
                    }
                    .font(.title2)
                    .buttonStyle(.bordered)
                    Text("Native player controls also support scrubbing, full screen, AirPlay, and Picture in Picture.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onReceive(player.publisher(for: \.rate)) { playing = $0 != 0 }
        }
    }

    private func skip(_ seconds: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .infinity
        let upper = duration.isFinite ? duration : .infinity
        player.seek(to: CMTime(seconds: min(upper, max(0, current + seconds)), preferredTimescale: 600))
    }
}
