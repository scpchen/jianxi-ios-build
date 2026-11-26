import SwiftUI

@main
struct JianxiApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(model.colorScheme)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.alipayReturned() }
                }
        }
    }
}