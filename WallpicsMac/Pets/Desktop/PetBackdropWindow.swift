import AppKit

final class PetBackdropWindow: NSWindow {
    let screenID: CGDirectDisplayID
    private let imageView = NSImageView()

    init(screen: NSScreen, screenID: CGDirectDisplayID) {
        self.screenID = screenID
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = PetBackdropWindow.backdropLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        imageView.frame = CGRect(origin: .zero, size: screen.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        contentView = imageView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(image: NSImage) {
        imageView.image = image
    }

    static var backdropLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    }
}
