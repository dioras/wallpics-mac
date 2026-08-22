import AppKit

final class DesktopPetWindow: NSWindow {
    let screenID: CGDirectDisplayID
    let petView = PetLayerView(frame: .zero)

    init(screen: NSScreen, screenID: CGDirectDisplayID) {
        self.screenID = screenID
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = DesktopPetWindow.behindIconsLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        petView.frame = CGRect(origin: .zero, size: screen.frame.size)
        petView.autoresizingMask = [.width, .height]
        contentView = petView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static var behindIconsLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
