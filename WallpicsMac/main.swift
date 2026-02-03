import Cocoa

// Keep delegate as a global to prevent deallocation
let delegate = AppDelegate()

autoreleasepool {
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
