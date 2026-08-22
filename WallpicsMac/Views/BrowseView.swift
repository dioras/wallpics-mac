import SwiftUI

struct BrowseView: View {
    @Bindable var model: BrowseViewModel
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: Theme.Space.l)]

    private var featuredWallpaper: Wallpaper? {
        env.selectedWallpaper ?? model.filteredWallpapers.first
    }

    private var gridWallpapers: [Wallpaper] {
        if model.isSearching { return model.filteredWallpapers }
        // The Most Popular strip + featured hero already show some of these; drop them so the grid
        // doesn't repeat them (by identity; the hero may be an import).
        let featuredID = featuredWallpaper?.id
        let popular = Set(model.popularRail.map(\.id))
        let deduped = model.filteredWallpapers.filter { !popular.contains($0.id) && $0.id != featuredID }
        // A small collection (Shaders has ~6 total) can be entirely consumed by the strip + hero,
        // leaving "All Wallpapers" blank — in that case show everything but the hero so it's never empty.
        if deduped.count < 6 {
            return model.filteredWallpapers.filter { $0.id != featuredID }
        }
        return deduped
    }

    /// Warm the next ~12 thumbnails as each card appears so scrolling stays instant instead of
    /// flashing spinners. Thumbnails are ~25KB, so the lookahead is cheap.
    private func prefetchAhead(from index: Int) {
        let items = gridWallpapers
        let end = min(index + 13, items.count)
        guard index + 1 < end else { return }
        let urls = items[(index + 1)..<end].compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }
        Task { await ImageLoader.shared.prefetch(urls) }
    }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                FeaturedHero(wallpaper: featuredWallpaper, bottomInset: 132)
                // The strip over the hero IS "Most Popular" now — tapping a card features it above.
                heroCarousel
            }
            .frame(height: max(420, geo.size.height * 0.74))

            BrowseToolbar(
                collection: model.collection,
                onCollection: model.setCollection
            )
            if !model.categories.isEmpty && !model.isSearching {
                categoryRows
            }

            if !model.isSearching {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Wallpapers")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Text("\(model.wallpapers.count) wallpapers")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    // Sort lives next to the content it orders (the client wanted it out of the
                    // tucked-away top-right icon), as a visible pill rather than a bare glyph.
                    SortMenu(sortOrder: model.sortOrder, onSort: model.setSort)
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.s)
            }

            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(Array(gridWallpapers.enumerated()), id: \.element.id) { index, wallpaper in
                    WallpaperCard(wallpaper: wallpaper, isSelected: env.detailWallpaper?.id == wallpaper.id)
                        .onTapGesture {
                            withAnimation(Motion.transition) { env.detailWallpaper = wallpaper }
                        }
                        .onAppear { prefetchAhead(from: index) }
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
            .padding(.bottom, Theme.Space.xxl)

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
        .task {
            await model.loadCategoriesIfNeeded()
            await model.loadPopularRail()
        }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// The small strip over the featured hero — this is "Most Popular" now. Tapping a card features
    /// it above. Filled with real backend-popular content that reacts to the selected category.
    private var heroCarousel: some View {
        HWheelScroll {
            HStack(spacing: Theme.Space.m) {
                ForEach(model.popularRail) { wp in
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
            .animation(Motion.hover, value: featuredWallpaper?.id)
        }
        .frame(height: 132)
    }

    /// One4Wall-style category chips: a row of root categories, plus a second row of
    /// subcategories when the selected root has children.
    private var categoryRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HWheelScroll {
                HStack(spacing: Theme.Space.s) {
                    CategoryChip(title: String(localized: "All"), isSelected: model.selectedCategory == nil) {
                        model.selectCategory(nil)
                    }
                    ForEach(model.categories) { category in
                        CategoryChip(title: category.cleanName, isSelected: model.selectedCategory?.id == category.id) {
                            model.selectCategory(category)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
            .frame(height: 40)
            if let parent = model.selectedCategory, !model.availableSubcategories.isEmpty {
                HWheelScroll {
                    HStack(spacing: Theme.Space.s) {
                        CategoryChip(title: String(localized: "All \(parent.cleanName)"),
                                     isSelected: model.selectedSubcategory == nil, isSub: true) {
                            model.selectSubcategory(nil)
                        }
                        ForEach(model.availableSubcategories) { sub in
                            CategoryChip(title: sub.cleanName, isSelected: model.selectedSubcategory?.id == sub.id, isSub: true) {
                                model.selectSubcategory(sub)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
                .frame(height: 32)
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
    let collection: WallpaperCollection
    let onCollection: (WallpaperCollection) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            CollectionFilter(selection: collection, onSelect: onCollection)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
    }
}

/// Visible sort control that sits by the "All Wallpapers" header. Shows the active order + a
/// chevron so it reads as a real menu, not a bare glyph tucked in the corner.
private struct SortMenu: View {
    let sortOrder: SortOrder
    let onSort: (SortOrder) -> Void

    var body: some View {
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
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                Text(sortOrder.label).font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liquidGlass(in: Capsule())
        .help(String(localized: "Sort wallpapers"))
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

/// One4Wall-style section header: bold title + muted subtitle on the left, optional
/// "See all" pill on the right.
private struct SectionHeader: View {
    let title: String
    let subtitle: String
    let seeAllAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if let seeAllAction {
                Button(action: seeAllAction) {
                    Text("See all")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.s)
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
