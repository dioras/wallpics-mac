import SwiftUI

struct BrowseView: View {
    @Bindable var model: BrowseViewModel
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: Theme.Space.l)]

    var body: some View {
        ScrollView {
            if !model.imported.isEmpty && !model.isSearching {
                uploadsSection
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
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .refreshable { await model.reload() }
        .task { await model.loadImports() }
        .safeAreaInset(edge: .top, spacing: 0) {
            BrowseToolbar(
                query: $model.query,
                sortOrder: model.sortOrder,
                onSort: model.setSort,
                isImporting: model.isImporting,
                onImport: importWallpaper
            )
        }
    }

    private func importWallpaper() {
        Task {
            if let wp = await model.importWallpaper() {
                withAnimation(Motion.transition) { env.selectedWallpaper = wp }
            }
        }
    }

    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Your Uploads")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.l)
            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(model.imported) { wallpaper in
                    WallpaperCard(wallpaper: wallpaper, isSelected: env.selectedWallpaper?.id == wallpaper.id)
                        .onTapGesture {
                            withAnimation(Motion.transition) { env.selectedWallpaper = wallpaper }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task {
                                    if env.selectedWallpaper?.id == wallpaper.id { env.selectedWallpaper = nil }
                                    await model.removeImport(wallpaper)
                                }
                            } label: {
                                Label("Remove Upload", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .animation(Motion.reward, value: model.imported.map(\.id))

            Divider().padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.s)
        }
        .padding(.top, Theme.Space.l)
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
    let isImporting: Bool
    let onImport: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
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
            .frame(minWidth: 80, maxWidth: 280, alignment: .leading)
            .liquidGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            .animation(Motion.hover, value: searchFocused)

            Spacer(minLength: Theme.Space.s)

            Button(action: onImport) {
                HStack(spacing: Theme.Space.s) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text("Upload").lineLimit(1)
                }
                .font(.callout.weight(.medium))
                .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule())

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
                Label(sortOrder.label, systemImage: "arrow.up.arrow.down")
                    .font(.callout.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule())
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(.thinMaterial)
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
