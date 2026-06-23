import SwiftUI

struct WidgetsView: View {
    @Bindable var model: WidgetsViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var editor: WidgetEditorModel?
    @State private var desktop = DesktopWidgetManager.shared

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: Theme.Space.l)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                toolbar
                content
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .environment(\.colorScheme, .dark)
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
            Button { editor = WidgetEditorModel(creating: .polaroid) } label: { Label("Polaroid Widget", systemImage: "photo.stack") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                Text("New").font(.callout.weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.55)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(.black)
            .background(.white, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Create a widget from your photos"))
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
            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(model.filteredItems) { item in
                    WidgetGalleryTile(item: item)
                        .onTapGesture { openEditor(for: item) }
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
        ScrollView(.horizontal, showsIndicators: false) {
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
    }

    private func openEditor(for item: WidgetCatalogItem) {
        let kind = item.resolvedKind
        editor = WidgetEditorModel(creating: kind, family: kind.supportedFamilies.first ?? .small, source: item)
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
