import Cocoa

autoreleasepool {
    MainActor.assumeIsolated {
        // `delegate` is held strongly for the entire lifetime of `run()`. NSApplication.delegate
        // is a weak reference, so without this strong local the delegate would deallocate and
        // applicationDidFinishLaunching would never fire (no window, no setup).
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
