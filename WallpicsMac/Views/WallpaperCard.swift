import SwiftUI

struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool

    @State private var isHovering = false

    /// Deterministic muted placeholder tint per wallpaper, so the grid looks intentional
    /// while thumbnails stream in rather than flashing uniform gray.
    static func tint(for id: Int) -> Color {
        let hue = Double((id &* 2654435761) % 360) / 360.0
        return Color(hue: hue, saturation: 0.22, brightness: 0.20)
    }

    var body: some View {
        ThumbnailView(
            url: wallpaper.thumbnailURL,
            placeholderTint: Self.tint(for: wallpaper.id)
        )
        .aspectRatio(16.0 / 10.0, contentMode: .fill)
        .frame(minHeight: 140)
        .clipped()
        .overlay { hoverScrim }
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .topTrailing) { premiumBadge }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : .white.opacity(isHovering ? 0.12 : 0), lineWidth: isSelected ? 2.5 : 1)
        }
        .scaleEffect(isHovering ? 1.025 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.35 : 0.12), radius: isHovering ? 16 : 6, y: isHovering ? 8 : 3)
        .animation(Motion.hover, value: isHovering)
        .animation(Motion.hover, value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var hoverScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.55), .clear, .clear],
            startPoint: .bottom, endPoint: .top
        )
        .opacity(isHovering ? 1 : 0)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(wallpaper.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(wallpaper.width) × \(wallpaper.height)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(12)
        .opacity(isHovering ? 1 : 0)
        .offset(y: isHovering ? 0 : 6)
    }

    @ViewBuilder
    private var premiumBadge: some View {
        if wallpaper.isPremiumContent {
            Image(systemName: "crown.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(7)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .padding(8)
        }
    }
}
