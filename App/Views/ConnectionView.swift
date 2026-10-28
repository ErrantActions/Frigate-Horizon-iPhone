import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var authenticate = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.cyan)
                        Text("Your cameras.\nA new horizon.")
                            .font(.largeTitle.bold())
                        Text("Connect directly to your Frigate Horizon server. Native video, private by design.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                }
                .listRowBackground(Color.clear)
                Section("Server") {
                    TextField("https://frigate.example.com", text: $model.serverText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("serverAddress")
                    Toggle("Sign in with Frigate credentials", isOn: $authenticate)
                    if authenticate {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                }
                if let error = model.error {
                    Section { ErrorNotice(message: error) }
                }
                Section {
                    Button {
                        Task {
                            await model.connect(username: username, password: password, authenticate: authenticate)
                            password = ""
                        }
                    } label: {
                        HStack {
                            Text(model.isConnecting ? "Connecting" : "Connect")
                            Spacer()
                            if model.isConnecting { ProgressView() }
                            else { Image(systemName: "arrow.right") }
                        }
                    }
                    .disabled(model.isConnecting || model.serverText.isEmpty
                        || (authenticate && (username.isEmpty || password.isEmpty)))
                    .accessibilityIdentifier("connectButton")
                } footer: {
                    Text("Use the server root, including its port or proxy base path. HTTPS requires a certificate trusted by your iPhone. Passwords are never saved; sessions are stored in this device's Keychain.")
                }
            }
            .navigationTitle("Frigate Horizon")
            .disabled(model.isConnecting)
        }
    }
}
