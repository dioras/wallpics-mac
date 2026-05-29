import Foundation

@MainActor
enum OnboardingPresenter {
    private static let key = "didCompleteOnboarding"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func show() {
        AppEnvironment.shared.showOnboarding = true
    }
}
