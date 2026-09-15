import SwiftUI
import AppKit

@MainActor
final class RailScroller: ObservableObject {
    @Published private(set) var canScrollLeft = false
    @Published private(set) var canScrollRight = false
    fileprivate weak var scrollView: NSScrollView?

    fileprivate func refresh() {
        guard let scrollView, let document = scrollView.documentView else {
            canScrollLeft = false
            canScrollRight = false
            return
        }
        let origin = scrollView.contentView.bounds.origin.x
        let maxX = max(0, document.frame.width - scrollView.contentView.bounds.width)
        let left = origin > 1
        let right = origin < maxX - 1
        if left != canScrollLeft { canScrollLeft = left }
        if right != canScrollRight { canScrollRight = right }
    }

    func page(_ direction: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let step = clip.bounds.width * 0.8 * direction
        let target = min(max(0, clip.bounds.origin.x + step), maxX)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(CGPoint(x: target, y: clip.bounds.origin.y))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                scrollView.reflectScrolledClipView(clip)
                self?.refresh()
            }
        }
    }
}

/// Horizontal scroller for rails. Horizontal wheel/trackpad deltas move the rail; vertical
/// deltas always go to the enclosing page, so a mouse wheel never gets trapped on a rail.
/// Pass a `RailScroller` to drive it from arrow buttons and to know whether it can move.
struct HWheelScroll<Content: View>: NSViewRepresentable {
    var scroller: RailScroller?
    @ViewBuilder var content: () -> Content

    init(scroller: RailScroller? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.scroller = scroller
        self.content = content
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = WheelRoutingScrollView()
        scrollView.convertsMouseWheel = scroller == nil
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
        if let scroller {
            scroller.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            hosting.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            context.coordinator.observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { _ in
                    MainActor.assumeIsolated { scroller.refresh() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: hosting, queue: .main) { _ in
                    MainActor.assumeIsolated { scroller.refresh() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { _ in
                    MainActor.assumeIsolated { scroller.refresh() }
                }
            ]
            DispatchQueue.main.async { scroller.refresh() }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.hosting?.rootView = AnyView(content())
        if let scroller {
            DispatchQueue.main.async { scroller.refresh() }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.observers.forEach { NotificationCenter.default.removeObserver($0) }
        coordinator.observers.removeAll()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<AnyView>?
        var observers: [NSObjectProtocol] = []
    }
}

/// A rail with hover-revealed arrow buttons on both ends.
struct HRail<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @StateObject private var scroller = RailScroller()
    @State private var isHovering = false

    var body: some View {
        HWheelScroll(scroller: scroller, content: content)
            .overlay(alignment: .leading) {
                arrow(direction: -1, symbol: "chevron.left", visible: scroller.canScrollLeft)
            }
            .overlay(alignment: .trailing) {
                arrow(direction: 1, symbol: "chevron.right", visible: scroller.canScrollRight)
            }
            .onHover { isHovering = $0 }
    }

    private func arrow(direction: CGFloat, symbol: String, visible: Bool) -> some View {
        Button {
            scroller.page(direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.m)
        .opacity(visible && isHovering ? 1 : 0)
        .allowsHitTesting(visible && isHovering)
        .animation(Motion.hover, value: isHovering)
        .animation(Motion.hover, value: visible)
        .help(direction < 0 ? String(localized: "Scroll left") : String(localized: "Scroll right"))
    }
}

private final class WheelRoutingScrollView: NSScrollView {
    var convertsMouseWheel = false

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        guard convertsMouseWheel, !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 else {
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
