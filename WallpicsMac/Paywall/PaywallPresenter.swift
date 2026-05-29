import Foundation

@MainActor
enum PaywallPresenter {
    static func show() {
        AppEnvironment.shared.showPaywall = true
    }
}
