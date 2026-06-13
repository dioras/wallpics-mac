import SwiftUI
import AppKit

/// Horizontal scroller that also responds to a vertical mouse wheel. A plain SwiftUI
/// horizontal `ScrollView` only scrolls from a horizontal trackpad swipe and ignores the
/// vertical deltas a standard mouse sends, which makes carousels/rails feel frozen for
/// mouse users. This hosts the content in an `NSScrollView` whose vertical wheel deltas are
/// redirected to horizontal motion; trackpad swipes pass through unchanged.
struct HWheelScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = WheelRedirectingScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay

        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
        context.coordinator.hosting = hosting
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.hosting?.rootView = AnyView(content())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<AnyView>?
    }
}

private final class WheelRedirectingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Pure-vertical input (mouse wheel) → scroll horizontally. A horizontal component
        // (trackpad swipe) is left to the normal handler.
        if event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 {
            let raw = event.scrollingDeltaY
            let delta = event.hasPreciseScrollingDeltas ? raw : raw * 10
            let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
            guard maxX > 0 else { super.scrollWheel(with: event); return }
            var origin = contentView.bounds.origin
            origin.x = min(max(0, origin.x - delta), maxX)
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
