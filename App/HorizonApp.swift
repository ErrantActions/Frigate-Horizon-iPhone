import SwiftUI

@main
struct HorizonApp: App {
    @UIApplicationDelegateAdaptor(HorizonApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var push = NativePushController.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let api = model.api {
                    HorizonRoot(api: api)
                        .id(ObjectIdentifier(api))
                } else {
                    ConnectionView()
                }
            }
            .environmentObject(model)
            .environmentObject(push)
            .tint(.cyan)
            .task { await model.restore() }
            .task(id: "\(model.api.map { String(describing: ObjectIdentifier($0)) } ?? "")-\(model.profile?.username ?? "")") {
                await push.attach(api: model.api, username: model.profile?.username)
            }
        }
    }
}
