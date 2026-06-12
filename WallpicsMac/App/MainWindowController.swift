import Cocoa
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "WallPics"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 920, height: 560)
        window.isRestorable = false

        let host = NSHostingController(
            rootView: ContentView()
                .environment(AppEnvironment.shared)
                .environment(StoreKitService.shared)
        )
        host.view.autoresizingMask = [.width, .height]
        window.contentViewController = host

        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.windows.allSatisfy({ !$0.isVisible || $0 == window }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var didMaximizeOnce = false

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !didMaximizeOnce, let screen = NSScreen.main ?? window?.screen {
            window?.setFrame(screen.visibleFrame, display: true)
            didMaximizeOnce = true
        }
        super.showWindow(sender)
    }
}
