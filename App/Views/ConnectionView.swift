import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var username = ""
    @State private var password = ""
    @State private var authenticate = true

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if geometry.size.width >= 760 && !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .top, spacing: 40) {
                                introduction.frame(maxWidth: 360)
                                connectionCard.frame(maxWidth: 440)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 28) {
                                introduction
                                connectionCard
                            }
                        }
                    }
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Horizon")
            .navigationBarTitleDisplayMode(.inline)
            .horizonScreen()
            .disabled(model.isConnecting)
            .onDisappear { password = "" }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            HorizonMark()
            VStack(alignment: .leading, spacing: 12) {
                Text("Your cameras.\nA new horizon.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("A considered space for your cameras, recordings, and everything that matters.")
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("Native video. No web wrapper.", systemImage: "play.rectangle")
                Label("Direct to your Frigate server.", systemImage: "network")
                Label("Sessions secured in Keychain.", systemImage: "lock.shield")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionCard: some View {
        HorizonCard {
            HorizonSectionHeader(title: "Connect to your horizon",
                subtitle: "Use your existing Frigate account.", systemImage: "network")
            field("Server address", systemImage: "server.rack") {
                TextField("https://frigate.example.com", text: $model.serverText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverAddress")
            }
            Toggle("Sign in with Frigate credentials", isOn: $authenticate)
                .font(.subheadline)
                .padding(.vertical, 6)
            if authenticate {
                field("Username", systemImage: "person") {
                    TextField("Your username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field("Password", systemImage: "key") {
                    SecureField("Your password", text: $password)
                        .textContentType(.password)
                }
            }
            if let error = model.error { ErrorNotice(message: error) }
            Button {
                Task {
                    await model.connect(username: username, password: password, authenticate: authenticate)
                    password = ""
                }
            } label: {
                HStack {
                    Text(model.isConnecting ? "Connecting" : "Connect")
                    Spacer()
                    if model.isConnecting { ProgressView().tint(HorizonPalette.onAccent) }
                    else { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(HorizonButtonStyle())
            .disabled(model.isConnecting || model.serverText.isEmpty
                || (authenticate && (username.isEmpty || password.isEmpty)))
            .accessibilityIdentifier("connectButton")
            Text("Enter the server root, including its port or proxy base path. Use HTTPS with a trusted certificate. Your password is never saved.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ title: String, systemImage: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: systemImage).foregroundStyle(HorizonPalette.accent)
                    .frame(width: 20).accessibilityHidden(true)
                content().textFieldStyle(.plain).font(.body)
            }
            .padding(14)
            .background(HorizonPalette.raised, in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                    .stroke(HorizonPalette.border, lineWidth: 1)
            }
        }
    }
}
