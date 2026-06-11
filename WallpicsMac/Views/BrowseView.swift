import SwiftUI

struct BrowseView: View {
    @Bindable var model: BrowseViewModel
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: Theme.Space.l)]

    /// The hero shows the user's pick, falling back to the freshest wallpaper of the page.
    private var featuredWallpaper: Wallpaper? {
        env.selectedWallpaper ?? model.filteredWallpapers.first
    }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                FeaturedHero(wallpaper: featuredWallpaper, bottomInset: 132)
                heroCarousel
            }
            .frame(height: max(520, geo.size.height))

            BrowseToolbar(
                query: $model.query,
                sortOrder: model.sortOrder,
                onSort: model.setSort,
                collection: model.collection,
                onCollection: model.setCollection
            )
            if !model.categories.isEmpty && !model.isSearching {
                categoryRows
            }

            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(model.filteredWallpapers) { wallpaper in
                    WallpaperCard(wallpaper: wallpaper, isSelected: env.selectedWallpaper?.id == wallpaper.id)
                        .onTapGesture {
                            withAnimation(Motion.transition) { env.selectedWallpaper = wallpaper }
                        }
                        .scrollTransition { content, phase in
                            content
                                .opacity(phase.isIdentity ? 1 : 0.35)
                                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                        }
                }
                if model.canLoadMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.xl)
                        .onAppear { Task { await model.loadNextPage() } }
                }
            }
            .padding(Theme.Space.l)

            if let error = model.errorMessage {
                ErrorBanner(message: error) { Task { await model.reload() } }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.l)
            }

            if !model.isLoading && model.filteredWallpapers.isEmpty && model.errorMessage == nil {
                if model.isSearching {
                    searchEmptyState.padding(.top, 80)
                } else {
                    emptyState.padding(.top, 80)
                }
            }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .refreshable { await model.reload() }
        .task { await model.loadCategoriesIfNeeded() }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// Quick-pick strip under the hero — tapping a card features it above, One4Wall style.
    private var heroCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.m) {
                ForEach(model.filteredWallpapers.prefix(14)) { wp in
                    let active = featuredWallpaper?.id == wp.id
                    Button {
                        withAnimation(Motion.transition) { env.selectedWallpaper = wp }
                    } label: {
                        ThumbnailView(url: wp.thumbnailURL, placeholderTint: WallpaperCard.tint(for: wp.id))
                            .frame(width: 152, height: 94)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(active ? .white : .white.opacity(0.12),
                                                  lineWidth: active ? 2.5 : 1)
                            }
                            .scaleEffect(active ? 1.04 : 1)
                            .shadow(color: .black.opacity(active ? 0.5 : 0.2), radius: active ? 12 : 5, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.l)
        }
        .animation(Motion.hover, value: featuredWallpaper?.id)
    }

    /// One4Wall-style category chips: a row of root categories, plus a second row of
    /// subcategories when the selected root has children.
    private var categoryRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    CategoryChip(title: String(localized: "All"), isSelected: model.selectedCategory == nil) {
                        model.selectCategory(nil)
                    }
                    ForEach(model.categories) { category in
                        CategoryChip(title: category.name, isSelected: model.selectedCategory?.id == category.id) {
                            model.selectCategory(category)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
            if let parent = model.selectedCategory, !model.availableSubcategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        CategoryChip(title: String(localized: "All \(parent.name)"),
                                     isSelected: model.selectedSubcategory == nil, isSub: true) {
                            model.selectSubcategory(nil)
                        }
                        ForEach(model.availableSubcategories) { sub in
                            CategoryChip(title: sub.name, isSelected: model.selectedSubcategory?.id == sub.id, isSub: true) {
                                model.selectSubcategory(sub)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.bottom, Theme.Space.m)
        .animation(Motion.hover, value: model.selectedCategory?.id)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .modifier(BreatheEffect())
            Text("Nothing here yet")
                .font(.title2.weight(.semibold))
            Text("Pull to refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // Search matches the wallpapers loaded so far. Let the user pull in more on demand
    // (one page per tap — never an auto-firing loop).
    private var searchEmptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matches in the loaded wallpapers")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if model.hasMore {
                Button("Load more wallpapers") { Task { await model.loadNextPage(force: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.xl)
    }
}

private struct BrowseToolbar: View {
    @Binding var query: String
    let sortOrder: SortOrder
    let onSort: (SortOrder) -> Void
    let collection: WallpaperCollection
    let onCollection: (WallpaperCollection) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            CollectionFilter(selection: collection, onSelect: onCollection)

            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search wallpapers", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            // Flex to fill the space between the filter and the actions so it grows with the
            // window instead of staying a small fixed pill beside empty space. minWidth keeps
            // the "Search wallpapers" placeholder from ever truncating.
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            .liquidGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            .animation(Motion.hover, value: searchFocused)

            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        onSort(order)
                    } label: {
                        if order == sortOrder { Image(systemName: "checkmark") }
                        Text(order.label)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .liquidGlass(in: Circle())
            .help(sortOrder.label)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
    }
}

/// Primary mode switch between the three wallpaper collections (Photos / Live / Shaders).
/// A capsule of segments matching the toolbar's liquid-glass language; active segment fills accent.
private struct CollectionFilter: View {
    let selection: WallpaperCollection
    let onSelect: (WallpaperCollection) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WallpaperCollection.allCases) { item in
                let active = item == selection
                Button { onSelect(item) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.systemImage)
                        Text(item.label).lineLimit(1)
                    }
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

/// Capsule filter chip. Root categories are solid-on-select; subcategory chips are slightly
/// smaller so the two rows read as a hierarchy.
private struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    var isSub: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isSub ? .caption.weight(.medium) : .callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, isSub ? Theme.Space.m : 15)
                .padding(.vertical, isSub ? 5 : 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.black) : AnyShapeStyle(.white.opacity(0.75)))
                .background {
                    if isSelected {
                        Capsule().fill(.white)
                    } else {
                        Capsule().fill(.white.opacity(0.07))
                    }
                }
                .overlay {
                    if !isSelected {
                        Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: onRetry)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
        }
        .padding(Theme.Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(.yellow.opacity(0.25), lineWidth: 1))
    }
}

/// Calm idle "breathing" for empty-state symbols. macOS 15+ gets the real effect;
/// older falls back to a gentle opacity pulse.
struct BreatheEffect: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.breathe)
        } else {
            content
                .opacity(on ? 1 : 0.6)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: on)
                .onAppear { on = true }
        }
    }
}
