import SwiftUI
import HorizonCore

struct ErrorNotice: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HorizonPalette.warm)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(message).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Try again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(HorizonButtonStyle(.secondary))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HorizonPalette.surface, in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                .stroke(HorizonPalette.warm.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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
                ProgressView().tint(HorizonPalette.accent)
            }
        }
        .frame(width: width, height: height)
        .background(HorizonPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(HorizonPalette.border, lineWidth: 1) }
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
