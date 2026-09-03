import SwiftUI
import AppKit

/// Horizontal scroller that also responds to a vertical mouse wheel. A plain SwiftUI
/// horizontal `ScrollView` only scrolls from a horizontal trackpad swipe and ignores the
/// vertical deltas a standard mouse sends, which makes carousels/rails feel frozen for
/// mouse users. This hosts the content in an `NSScrollView` whose mouse-wheel deltas are
/// redirected to horizontal motion until the rail reaches an end, after which the event is
/// handed to the enclosing page; trackpad vertical swipes always scroll the page.
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
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * 10
        let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        let origin = contentView.bounds.origin
        let target = min(max(0, origin.x - delta), maxX)
        guard maxX > 0, abs(target - origin.x) > 0.5 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        contentView.scroll(to: CGPoint(x: target, y: origin.y))
        reflectScrolledClipView(contentView)
    }
}
