import AppKit
import SwiftUI

@main
struct SafeShareLocalApp: App {
    @StateObject private var vm = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        applyAppIconIfAvailable()
    }

    var body: some Scene {
        WindowGroup("SafeShare Local Privacy") {
            ContentView(vm: vm)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
    }

    private func applyAppIconIfAvailable() {
        guard let iconURL = Bundle.module.url(
            forResource: "SafeShareIcon-master-1024",
            withExtension: "png",
            subdirectory: "Resources/AppIcon"
        ) else { return }

        guard let image = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
