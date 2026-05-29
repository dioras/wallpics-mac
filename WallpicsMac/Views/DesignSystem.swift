import SwiftUI
import AppKit

// Central design tokens. Keep visual constants here so every screen stays consistent
// and a single edit re-themes the whole app.

enum Theme {
    // Spacing — 4/8 grid.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // Corner radii.
    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
        static let hero: CGFloat = 22
    }

    // The single accent. Reserved for selection, primary actions, active state.
    static let accent = Color.accentColor
}

// Motion presets. Names describe intent, not duration, so call sites read clearly.
enum Motion {
    /// Frequent UI state — hover, selection, toggles.
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.72)
    /// View / sheet / step transitions. No overshoot, "expensive" feel.
    static let transition = Animation.smooth(duration: 0.38)
    /// Small rewarding moments — favorite, success.
    static let reward = Animation.bouncy(duration: 0.42, extraBounce: 0.18)
    /// Press feedback.
    static let press = Animation.snappy(duration: 0.18)
}

// MARK: - Liquid Glass

extension View {
    /// Tahoe Liquid Glass when available, a material fallback on macOS 14/15.
    /// Use for floating chrome only (toolbars, action bars, pills) — never content.
    @ViewBuilder
    func liquidGlass(in shape: some Shape = Capsule(), tinted: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if tinted {
                self.glassEffect(.regular.tint(Theme.accent.opacity(0.18)), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Button styles

/// Full-width primary call to action. Accent-filled, subtle press spring.
/// Reads premium across all supported macOS versions.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.accent.gradient)
                    .brightness(configuration.isPressed ? -0.05 : 0)
            )
            .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// Secondary action. Material/glass capsule, no shout.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(.primary)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryCTA: PrimaryButtonStyle { PrimaryButtonStyle() }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryCTA: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension View {
    /// One-shot SF Symbol bounce when `value` changes (macOS 14+); no-op on older.
    @ViewBuilder
    func symbolEffectBounce(value: some Equatable) -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}

// MARK: - App icon

/// The real app icon, presented as a polished brand mark. macOS app icons already carry
/// the squircle shape, so we just size it and add depth.
struct AppIconView: View {
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: size * 0.14, y: size * 0.06)
    }
}

// MARK: - Ambient backdrop

/// Soft, dark, depth-y backdrop used behind onboarding and the paywall.
/// Two offset radial glows over a near-black base read more expensive than a flat gradient.
struct AmbientBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
            RadialGradient(
                colors: [Theme.accent.opacity(0.28), .clear],
                center: .topLeading, startRadius: 0, endRadius: 520
            )
            RadialGradient(
                colors: [Color(red: 0.5, green: 0.2, blue: 0.7).opacity(0.22), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}
