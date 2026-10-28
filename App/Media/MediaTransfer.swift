import SwiftUI
import HorizonCore

struct SharedMediaFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class MediaTransfer: ObservableObject {
    @Published var file: SharedMediaFile?
    @Published var error: String?
    @Published private(set) var downloading = false
    private var task: Task<Void, Never>?
    private var downloadedURL: URL?

    func start(api: HorizonAPI, url: URL, fileExtension: String) {
        guard !downloading else { return }
        error = nil
        downloading = true
        task = Task {
            defer { downloading = false }
            do {
                try removeDownloadedFile()
                let result = try await api.download(url, fileExtension: fileExtension)
                downloadedURL = result
                file = SharedMediaFile(url: result)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func dismissShare() {
        do { try removeDownloadedFile() }
        catch { self.error = error.localizedDescription }
        file = nil
    }

    func cancel() { task?.cancel() }

    private func removeDownloadedFile() throws {
        guard let downloadedURL else { return }
        if FileManager.default.fileExists(atPath: downloadedURL.path) {
            try FileManager.default.removeItem(at: downloadedURL)
        }
        self.downloadedURL = nil
    }
}

struct NativeShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
