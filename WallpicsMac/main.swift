import Cocoa

@MainActor
func bootstrap() -> AppDelegate {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    return delegate
}

autoreleasepool {
    let _ = MainActor.assumeIsolated { bootstrap() }
    NSApplication.shared.run()
}
