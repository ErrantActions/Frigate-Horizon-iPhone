import SwiftUI
import HorizonCore

struct ErrorNotice: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
            if let retry { Button("Try again", action: retry) }
        }
        .foregroundStyle(.orange)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct DuoWorkspace<Primary: View, Secondary: View>: View {
    @Binding var foldMode: FoldMode
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary

    var body: some View {
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split.axes(foldMode == .tabletop
                ? Axis.Set.vertical : Axis.Set.horizontal.union(.vertical)))
            .onGeometryChange(for: FoldMode.self) { geometry in
                FoldMode.detect(
                    activeDivisions: geometry.reservedRegions(kind: .division).map(\.frame),
                    in: CGRect(origin: .zero, size: geometry.size)
                )
            } action: {
                foldMode = $0
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        GeometryReader { geometry in
            let layout = geometry.size.width >= 700
                ? AnyLayout(HStackLayout(spacing: 16))
                : AnyLayout(VStackLayout(spacing: 16))
            layout {
                primary.frame(maxWidth: .infinity, maxHeight: .infinity)
                secondary.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { foldMode = .flat }
    }
}

struct ServerImage: View {
    let api: HorizonAPI
    private let source: Source
    private let width: CGFloat
    private let height: CGFloat
    @State private var image: UIImage?
    @State private var error: String?

    private enum Source: Hashable {
        case review(String)
        case url(URL)
    }

    init(api: HorizonAPI, path: String) {
        self.api = api; source = .review(path); width = 96; height = 64
    }

    init(api: HorizonAPI, url: URL, width: CGFloat = 96, height: CGFloat = 64) {
        self.api = api; source = .url(url); self.width = width; self.height = height
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let error {
                Image(systemName: "photo.badge.exclamationmark")
                    .accessibilityLabel(error)
            } else {
                ProgressView()
            }
        }
        .frame(width: width, height: height)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: source) {
            image = nil
            error = nil
            do {
                let url: URL
                switch source {
                case .review(let path): url = try api.address.reviewThumbnail(path)
                case .url(let value): url = value
                }
                let bytes = try await api.image(url)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: bytes) else { throw HorizonError.unexpectedResponse }
                image = decoded
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
