import SwiftUI

@main
struct SafeShareMacApp: App {
    @StateObject private var vm = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("SafeShare Local Privacy") {
            ContentView(vm: vm)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
