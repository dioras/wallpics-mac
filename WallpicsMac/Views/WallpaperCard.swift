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
        thumbnail
        .aspectRatio(16.0 / 10.0, contentMode: .fill)
        .frame(minHeight: 140)
        .clipped()
        .overlay { hoverScrim }
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .topLeading) { kindBadge }
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
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
            Text(verbatim: "\(wallpaper.width) × \(wallpaper.height)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        }
        .padding(12)
        .opacity(isHovering ? 1 : 0)
        .offset(y: isHovering ? 0 : 6)
    }

    /// Live wallpapers play their animated preview right in the grid; everything else shows
    /// the static thumbnail.
    @ViewBuilder
    private var thumbnail: some View {
        if let animated = wallpaper.animatedPreviewURL {
            AnimatedWebPView(url: animated, fallbackURL: wallpaper.thumbnailURL, isActive: isHovering)
        } else {
            ThumbnailView(
                url: wallpaper.thumbnailURL,
                placeholderTint: Self.tint(for: wallpaper.id)
            )
        }
    }

    @ViewBuilder
    private var kindBadge: some View {
        HStack(spacing: 0) {
            if wallpaper.isNew {
                BadgePill(background: .green) {
                    Text(verbatim: "NEW")
                }
            }
            switch wallpaper.mediaType {
            case .photo:
                EmptyView()
            case .live:
                BadgePill(background: .black.opacity(0.65)) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Text(verbatim: "LIVE")
                }
            case .shader:
                BadgePill(background: .black.opacity(0.65)) {
                    Image(systemName: "sparkles").font(.system(size: 7, weight: .bold))
                    Text(verbatim: "SHADER")
                }
            }
        }
    }

    @ViewBuilder
    private var premiumBadge: some View {
        if wallpaper.isPremiumContent {
            BadgePill(background: .orange) {
                Text(verbatim: "PRO")
            }
        }
    }
}

/// Compact corner badge in the One4Wall idiom: bold mini-caps on a solid rounded chip.
struct BadgePill<Content: View>: View {
    let background: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
    }
}
