import SwiftUI
import HorizonCore

struct ConnectionIssueNotice: View {
    let issue: ConnectionIssue
    let detail: String?

    init(issue: ConnectionIssue, detail: String? = nil) {
        self.issue = issue
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(issue.title, systemImage: "wifi.exclamationmark")
                .font(.headline)
            Text(issue.guidance)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if issue.kind == .other, let detail {
                ErrorNotice(message: detail)
            }
            ShareLink(item: issue.diagnosticSummary) {
                Label("Share connection diagnostics", systemImage: "square.and.arrow.up")
                    .font(.caption)
                    .frame(minHeight: 44)
            }
            Text("Shared diagnostics contain only the error category and status codes, not your address, account, cookies or camera names.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct ReauthenticateView: View {
    let username: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                HorizonCard {
                    HorizonSectionHeader(title: "Sign in again",
                        subtitle: "Renew this account's session without forgetting your layouts.",
                        systemImage: "person.crop.circle.badge.checkmark")
                    LabeledContent("Account", value: username)
                    if let api = model.api {
                        LabeledContent("Server", value: api.address.url.absoluteString)
                    }
                    SecureField("Current password", text: $password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                        .submitLabel(.go)
                        .onSubmit { signIn() }
                        .padding(14)
                        .background(HorizonPalette.raised,
                            in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
                    if let issue = model.connectionIssue {
                        ConnectionIssueNotice(issue: issue, detail: model.error)
                    } else if let error = model.error {
                        ErrorNotice(message: error)
                    }
                    Button(action: signIn) {
                        HStack {
                            Text(model.isConnecting ? "Signing in" : "Sign in")
                            Spacer()
                            if model.isConnecting { ProgressView() }
                            else { Image(systemName: "arrow.right") }
                        }
                    }
                    .buttonStyle(HorizonButtonStyle())
                    .disabled(password.isEmpty || model.isConnecting)
                    Text("Your password is never saved. Saved camera groups and layouts are kept. Signing in does not enable notifications or change your server settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .horizonScreen()
            .navigationTitle("Reconnect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isConnecting)
                }
            }
            .interactiveDismissDisabled(model.isConnecting)
            .onAppear { passwordFocused = true }
            .onDisappear { password = "" }
        }
    }

    private func signIn() {
        guard !password.isEmpty, !model.isConnecting else { return }
        passwordFocused = false
        Task {
            let success = await model.reauthenticate(password: password)
            password = ""
            if success { dismiss() }
        }
    }
}
