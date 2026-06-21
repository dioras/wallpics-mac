import SwiftUI

/// A catalog item in the gallery grid — its backend preview thumbnail with the exact card chrome
/// `WallpaperCard` uses (hover lift 1.025, matching shadow ramp, white hover stroke, hover caption,
/// pointing-hand cursor, `BadgePill`). Tapping opens the editor (handled by the parent).
struct WidgetGalleryTile: View {
    let item: WidgetCatalogItem
    @State private var isHovering = false

    var body: some View {
        ThumbnailView(url: item.thumbnailURL, placeholderTint: .white.opacity(0.06))
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay { hoverScrim }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topLeading) { interactiveBadge }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.12 : 0), lineWidth: 1)
            }
            .scaleEffect(isHovering ? 1.025 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.35 : 0.12), radius: isHovering ? 16 : 6, y: isHovering ? 8 : 3)
            .animation(Motion.hover, value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .help(item.name ?? item.resolvedKind.displayName)
    }

    private var hoverScrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear, .clear], startPoint: .bottom, endPoint: .top)
            .opacity(isHovering ? 1 : 0)
    }

    private var caption: some View {
        Text(item.name ?? item.resolvedKind.displayName)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
            .padding(12)
            .opacity(isHovering ? 1 : 0)
            .offset(y: isHovering ? 0 : 6)
    }

    @ViewBuilder
    private var interactiveBadge: some View {
        if item.resolvedKind.isInteractive {
            BadgePill(background: .black.opacity(0.65)) {
                Image(systemName: "hand.tap.fill").font(.system(size: 7, weight: .bold))
                Text(verbatim: "TAP")
            }
        }
    }
}

/// A user-created widget in the My Widgets grid — its live `WidgetRenderView` with the same card
/// chrome. Click toggles desktop placement; right-click for edit/delete. A green `BadgePill` marks
/// what's currently on the desktop.
struct MyWidgetTile: View {
    let instance: WidgetInstance
    let isPlaced: Bool
    var onToggleDesktop: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        WidgetRenderView(instance: instance)
            .aspectRatio(instance.family.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.04))
            .overlay { hoverScrim }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topTrailing) { placedBadge }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isPlaced ? Theme.accent.opacity(0.7) : .white.opacity(isHovering ? 0.12 : 0),
                                  lineWidth: isPlaced ? 2 : 1)
            }
            .scaleEffect(isHovering ? 1.025 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.35 : 0.12), radius: isHovering ? 16 : 6, y: isHovering ? 8 : 3)
            .animation(Motion.hover, value: isHovering)
            .animation(Motion.hover, value: isPlaced)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { onToggleDesktop() }
            .contextMenu {
                Button(isPlaced ? "Remove from Desktop" : "Place on Desktop",
                       systemImage: isPlaced ? "rectangle.badge.minus" : "rectangle.badge.plus",
                       action: onToggleDesktop)
                Button("Edit", systemImage: "pencil", action: onEdit)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .help(isPlaced ? String(localized: "On your desktop — click to remove") : String(localized: "Click to place on your desktop"))
    }

    private var hoverScrim: some View {
        LinearGradient(colors: [.black.opacity(0.6), .clear, .clear], startPoint: .bottom, endPoint: .top)
            .opacity(isHovering ? 1 : 0)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(instance.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
            Text(isHovering ? (isPlaced ? String(localized: "Click to remove") : String(localized: "Click to place")) : instance.kind.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        }
        .padding(12)
        .opacity(isHovering ? 1 : 0)
        .offset(y: isHovering ? 0 : 6)
    }

    @ViewBuilder
    private var placedBadge: some View {
        if isPlaced {
            BadgePill(background: .green) {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy))
                Text(verbatim: "ON DESKTOP")
            }
        }
    }
}
