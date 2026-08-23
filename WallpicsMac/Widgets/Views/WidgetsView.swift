import SwiftUI
import WidgetKit

struct WidgetsView: View {
    @Bindable var model: WidgetsViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var editor: WidgetEditorModel?
    @State private var desktop = DesktopWidgetManager.shared
    @State private var showNativeGuide = false
    @AppStorage("didDismissNativeWidgetCallout") private var didDismissNativeCallout = false

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: Theme.Space.l)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if !didDismissNativeCallout { nativeWidgetCallout }
                toolbar
                content
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showNativeGuide) { NativeWidgetGuide() }
        .task { await model.loadIfNeeded() }
        .task(id: env.widgetEditRequestID) {
            guard let id = env.widgetEditRequestID, let instance = model.store.instance(id: id) else { return }
            model.tab = .mine
            editor = WidgetEditorModel(editing: instance)
            env.widgetEditRequestID = nil
        }
        .sheet(item: $editor) { editorModel in
            WidgetEditorView(
                model: editorModel,
                onSaved: { saved in
                    editor = nil
                    model.tab = .mine
                    desktop.place(saved)
                },
                onCancel: { editor = nil }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Widgets")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("Customize and place live widgets on your desktop.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            newWidgetMenu
        }
        .padding(.top, Theme.Space.xl)
    }

    private var newWidgetMenu: some View {
        Menu {
            Button { editor = WidgetEditorModel(creating: .photo) } label: { Label("Photo Widget", systemImage: "photo") }
            Button { editor = WidgetEditorModel(creating: .video) } label: { Label("Video Widget", systemImage: "video") }
            Button { editor = WidgetEditorModel(creating: .polaroid) } label: { Label("Polaroid Widget", systemImage: "photo.stack") }
            Divider()
            Button { editor = WidgetEditorModel(creating: .dateTime) } label: { Label("Clock", systemImage: "clock") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                Text("New").font(.callout.weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
            }
            .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.blue, in: Capsule())
        .shadow(color: .blue.opacity(0.45), radius: 8, y: 2)
        .help(String(localized: "Create a widget from your photos or videos"))
    }

    /// Honest native-widget path. macOS gives apps no way to drop a widget on the desktop or open
    /// the gallery directly, so we guide the user through the one Apple-sanctioned flow and detect
    /// success automatically. Placing from a tile stays instant but is an app overlay, not native.
    private var nativeWidgetCallout: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Want it to snap with your other desktop widgets?")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text("Add WallPics as a real native macOS widget. Apple only allows this through the system Widget gallery — placing from a tile below is an instant app overlay instead.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button("Show me how") { showNativeGuide = true }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(.white)
                .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))

            Button {
                didDismissNativeCallout = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Dismiss"))
        }
        .padding(Theme.Space.m)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.m) {
            WidgetSegmentedToggle(selection: $model.tab)
            Spacer()
            searchField.frame(maxWidth: 260)
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search widgets", text: $model.query).textFieldStyle(.plain).font(.callout)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
        .liquidGlass(in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .gallery: galleryTab
        case .mine: myWidgetsTab
        }
    }

    @ViewBuilder
    private var galleryTab: some View {
        if !model.categoryChips.isEmpty { categoryChips }

        if model.isLoading && model.items.isEmpty {
            loadingState
        } else if let error = model.loadError, model.items.isEmpty {
            errorState(error)
        } else if model.filteredItems.isEmpty {
            emptyGalleryState
        } else {
            GalleryFlow(spacing: Theme.Space.l) {
                ForEach(model.filteredItems) { item in
                    WidgetGalleryTile(item: item, isPlaced: model.isCatalogItemPlaced(item))
                        .onTapGesture { placeOnDesktop(item) }
                        .contextMenu {
                            Button { placeOnDesktop(item) } label: {
                                Label("Place on Desktop", systemImage: "plus.rectangle.on.rectangle")
                            }
                            Button { openEditor(for: item) } label: {
                                Label("Customize\u{2026}", systemImage: "slider.horizontal.3")
                            }
                        }
                }
            }
            .animation(Motion.reward, value: model.filteredItems.map { $0.id ?? "" })
            if model.hasMore && model.query.isEmpty {
                ProgressView().controlSize(.small).tint(.white)
                    .frame(maxWidth: .infinity).padding(.top, Theme.Space.m)
                    .onAppear { Task { await model.loadMore() } }
            }
        }
    }

    private var categoryChips: some View {
        HWheelScroll {
            HStack(spacing: Theme.Space.s) {
                WidgetCategoryChip(title: String(localized: "All"), isSelected: model.selectedCategorySlug == nil) {
                    model.selectCategory(nil)
                }
                ForEach(model.categoryChips) { node in
                    if let slug = node.slug {
                        WidgetCategoryChip(title: node.name ?? slug, isSelected: model.selectedCategorySlug == slug) {
                            model.selectCategory(slug)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 40)
    }

    private func openEditor(for item: WidgetCatalogItem) {
        let kind = item.resolvedKind
        editor = WidgetEditorModel(creating: kind, family: kind.supportedFamilies.first ?? .small, source: item)
    }

    /// One-click "Desktop Widgets": download + seed the widget's assets, then drop it straight onto
    /// the desktop overlay. Widgets that need the user's own photo/video open the editor instead.
    private func placeOnDesktop(_ item: WidgetCatalogItem) {
        let kind = item.resolvedKind
        let editorModel = WidgetEditorModel(creating: kind, family: kind.supportedFamilies.first ?? .small, source: item)
        Task {
            await editorModel.prepare()
            if editorModel.canSave {
                let saved = editorModel.save()
                desktop.place(saved)
                model.tab = .mine
            } else {
                editor = editorModel   // needs your photo/video first
            }
        }
    }

    @ViewBuilder
    private var myWidgetsTab: some View {
        if model.myWidgets.isEmpty {
            emptyMineState
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(model.myWidgets) { instance in
                    MyWidgetTile(
                        instance: instance,
                        isPlaced: desktop.isPlaced(instance.id),
                        onToggleDesktop: {
                            if desktop.isPlaced(instance.id) { desktop.remove(instance.id) }
                            else { desktop.place(instance) }
                        },
                        onEdit: { editor = WidgetEditorModel(editing: instance) },
                        onDelete: {
                            desktop.remove(instance.id)
                            model.store.delete(id: instance.id)
                        }
                    )
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
            .animation(Motion.reward, value: model.myWidgets.map(\.id))
        }
    }

    private var loadingState: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.large).tint(.white)
            Text("Loading widgets…").font(.callout).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("Couldn't load widgets")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(message)
                .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            Button("Retry") { Task { await model.reload() } }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .foregroundStyle(.black).background(.white, in: Capsule())
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(.horizontal, Theme.Space.xl)
    }

    private var emptyGalleryState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
                .modifier(BreatheEffect())
            Text("No widgets found")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Try a different category or search.")
                .font(.callout).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var emptyMineState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(.white.opacity(0.04))
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .strokeBorder(.white.opacity(0.10), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                    .modifier(BreatheEffect())
                Text("No widgets yet")
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("Pick one from the Gallery, customize it, then place it on your desktop.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Browse Gallery") { model.tab = .gallery }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .foregroundStyle(.black).background(.white, in: Capsule())
                    .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.xxl)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.top, Theme.Space.l)
    }
}

private struct WidgetSegmentedToggle: View {
    @Binding var selection: WidgetsViewModel.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WidgetsViewModel.Tab.allCases) { tab in
                let active = tab == selection
                Button { selection = tab } label: {
                    Text(tab.label)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 6)
                        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background {
                            if active {
                                Capsule().fill(Theme.accent)
                                    .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .liquidGlass(in: Capsule())
        .fixedSize()
        .animation(Motion.hover, value: selection)
    }
}

private struct WidgetCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.black) : AnyShapeStyle(.white.opacity(0.75)))
                .background {
                    if isSelected { Capsule().fill(.white) }
                    else { Capsule().fill(.white.opacity(0.07)) }
                }
                .overlay {
                    if !isSelected { Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Guided add-to-desktop for a REAL native widget. macOS has no API to place a widget or open the
/// gallery, so we show the exact steps and poll WidgetCenter to auto-confirm the moment one appears.
private struct NativeWidgetGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var added = false
    @State private var poll: Task<Void, Never>?

    private let steps: [(String, String, String)] = [
        ("1", "Right-click an empty spot on your desktop", "cursorarrow.rays"),
        ("2", "Click \u{201C}Edit Widgets\u{201D}", "square.grid.2x2"),
        ("3", "Search \u{201C}WallPics\u{201D}, then drag a widget out", "magnifyingglass")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Add a native WallPics widget")
                    .font(.title2.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.5))
                }.buttonStyle(.plain)
            }
            Text("Apple only lets you add native widgets from the system gallery — it takes about 5 seconds:")
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(steps, id: \.0) { step in
                    HStack(spacing: Theme.Space.m) {
                        Text(step.0)
                            .font(.headline).foregroundStyle(.black)
                            .frame(width: 26, height: 26).background(.white, in: Circle())
                        Image(systemName: step.2).font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 22)
                        Text(step.1).font(.callout).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Theme.Space.m)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            detectionBanner
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .background(Color(white: 0.09))
        .environment(\.colorScheme, .dark)
        .onAppear { startPolling() }
        .onDisappear { poll?.cancel() }
    }

    private var detectionBanner: some View {
        HStack(spacing: Theme.Space.s) {
            if added {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Widget added — you'll see it on your desktop").foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.small).tint(.white)
                Text("Waiting for you to drag it out…").foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(Theme.Space.m)
        .background((added ? Color.green.opacity(0.14) : Color.white.opacity(0.06)),
                   in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .animation(Motion.hover, value: added)
    }

    private func startPolling() {
        poll = Task {
            while !Task.isCancelled && !added {
                if await Self.hasNativeWidget() {
                    await MainActor.run { withAnimation { added = true } }
                    break
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private static func hasNativeWidget() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                if case .success(let infos) = result {
                    continuation.resume(returning: infos.contains {
                        $0.kind == "WallpicsPhotoWidget" || $0.kind == "WallpicsMatchesWidget"
                    })
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}


/// Left-aligned wrapping row layout: every tile keeps its own width (native widget
/// aspect at a shared height) and rows wrap like text.
struct GalleryFlow: Layout {
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
