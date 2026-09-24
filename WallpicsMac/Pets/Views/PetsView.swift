import SwiftUI

struct PetsView: View {
    @Bindable var model: PetsViewModel
    @Environment(StoreKitService.self) private var store
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: Theme.Space.l)]
    private static let previewMaxHeight: CGFloat = 400
    private static let activeColumnWidth: CGFloat = 660
    private static let sideBySideMinWidth: CGFloat = 1180
    private static let gridInset: CGFloat = Theme.Space.m

    @State private var previewSize: PetSize = .medium
    @State private var previewAnchor: PetAnchor = .bottomTrailing
    @State private var previewSensitivity: PetSensitivity = .normal

    var body: some View {
        GeometryReader { geo in
            if let focused = model.focused, geo.size.width >= Self.sideBySideMinWidth {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        ScrollView(showsIndicators: false) {
                            focusCard(focused, sideBySide: true)
                                .padding(.bottom, Theme.Space.xxl)
                        }
                        .frame(width: Self.activeColumnWidth)
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            toolbar
                            ScrollView {
                                content
                                    .padding(Self.gridInset)
                                    .padding(.bottom, Theme.Space.xxl)
                            }
                            .padding(.horizontal, -Self.gridInset)
                            .padding(.top, -Self.gridInset)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        header
                        if let focused = model.focused {
                            focusCard(focused, sideBySide: false)
                        }
                        toolbar
                        content
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pets")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("Put a companion on your desktop. It watches your cursor.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if model.active != nil {
                Button {
                    model.desktop.toggleUserPause()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.desktop.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(model.desktop.isPaused ? "Resume pet" : "Pause pet")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Capsule())
            }
        }
        .padding(.top, Theme.Space.xl)
    }

    @ViewBuilder
    private func focusCard(_ pet: PetSpecies, sideBySide: Bool) -> some View {
        Group {
            if model.store.isActive(pet.slug) {
                activePetCard(pet, sideBySide: sideBySide)
            } else {
                previewCard(pet, sideBySide: sideBySide)
            }
        }
        .id(pet.slug)
        .transition(.opacity)
    }

    private func previewCard(_ pet: PetSpecies, sideBySide: Bool) -> some View {
        let locked = PetAccess.requiresPaywall(pet: pet, state: store.state, ownedIDs: model.submissions.unlockedPetIDs)
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            PetPlacementPreview(
                species: pet,
                size: locked ? previewSize : model.store.placement?.size ?? .medium,
                anchor: locked ? previewAnchor : model.store.placement?.anchor ?? .bottomCenter,
                sensitivity: locked ? previewSensitivity : model.store.placement?.sensitivity ?? .normal
            )
            .frame(maxWidth: .infinity, maxHeight: sideBySide ? nil : Self.previewMaxHeight, alignment: .topLeading)
            .allowsHitTesting(false)

            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.s) {
                        Text(model.displayName(for: pet))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        if locked {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill")
                                Text(verbatim: "PRO")
                            }
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white, in: Capsule(style: .continuous))
                        }
                    }
                    Text(pet.summary ?? String(localized: "Preview. It follows your cursor right on your desktop."))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                Button {
                    model.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close preview"))
            }

            if locked {
                placementControls(size: previewSize,
                                  sensitivity: previewSensitivity,
                                  anchor: previewAnchor,
                                  onSize: { previewSize = $0 },
                                  onSensitivity: { previewSensitivity = $0 },
                                  onAnchor: { previewAnchor = $0 })

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Button {
                        PaywallPresenter.show()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "crown.fill")
                            Text("Unlock with Pro")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Text("Every pet in the catalog comes with WallPics Pro.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Button {
                    model.place(pet)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pawprint.fill")
                        Text("Put on Desktop")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: sideBySide ? .infinity : 640, alignment: .leading)
        .padding(Theme.Space.l)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func activePetCard(_ pet: PetSpecies, sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            PetPlacementPreview(
                species: pet,
                size: model.store.placement?.size ?? .medium,
                anchor: model.store.placement?.anchor ?? .bottomTrailing,
                sensitivity: model.store.placement?.sensitivity ?? .normal
            )
            .frame(maxWidth: .infinity, maxHeight: sideBySide ? nil : Self.previewMaxHeight, alignment: .topLeading)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(for: pet))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    if let paused = model.desktop.pauseSummary {
                        HStack(spacing: 5) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 11))
                            Text(paused)
                        }
                        .font(.caption)
                        .foregroundStyle(.yellow.opacity(0.85))
                    } else {
                        Text("On your desktop, behind your icons.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                if let failure = model.desktop.loadFailure {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                        Text("This pet couldn't load — \(failure)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Space.s)
                        Button("Retry") { model.retry() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .foregroundStyle(.black)
                            .background(.white, in: Capsule())
                    }
                    .padding(Theme.Space.s)
                    .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }

                placementControls(size: model.store.placement?.size,
                                  sensitivity: model.store.placement?.sensitivity,
                                  anchor: model.store.placement?.anchor,
                                  onSize: model.setSize,
                                  onSensitivity: model.setSensitivity,
                                  onAnchor: model.setAnchor)

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle(isOn: Binding(
                        get: { model.store.placement?.showsProfileBackdrop ?? false },
                        set: { model.setProfileBackdrop($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Name card backdrop").font(.callout)
                            Text("Replaces your wallpaper with a plain card showing this pet's details.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.accent)

                    if let failure = model.backdrop.lastError {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.yellow.opacity(0.9))
                    }

                    if model.store.placement?.showsProfileBackdrop == true {
                        PetProfileEditor(model: model, species: pet)
                    }
                }

                Toggle(isOn: Binding(
                    get: { model.store.placement?.allScreens ?? true },
                    set: { model.setAllScreens($0) }
                )) {
                    Text("Show on every display").font(.callout)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)

                Divider().overlay(.white.opacity(0.12))

                HStack {
                    Spacer()
                    Button {
                        model.removeFromDesktop()
                    } label: {
                        Label(String(localized: "Remove from Desktop"), systemImage: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(.red.opacity(0.55), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Remove \(model.displayName(for: pet)) from Desktop"))
                }
            }
            .frame(maxWidth: sideBySide ? .infinity : 640, alignment: .leading)
        }
        .padding(Theme.Space.l)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func placementControls(size: PetSize?,
                                   sensitivity: PetSensitivity?,
                                   anchor: PetAnchor?,
                                   onSize: @escaping (PetSize) -> Void,
                                   onSensitivity: @escaping (PetSensitivity) -> Void,
                                   onAnchor: @escaping (PetAnchor) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                optionRow(title: String(localized: "Size")) {
                    ForEach(PetSize.allCases) { option in
                        PetChip(title: option.label, isSelected: size == option) {
                            onSize(option)
                        }
                    }
                }
                optionRow(title: String(localized: "Sensitivity")) {
                    ForEach(PetSensitivity.allCases) { level in
                        PetChip(title: level.label, isSelected: sensitivity == level) {
                            onSensitivity(level)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Position")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: Theme.Space.m) {
                        PetPositionGrid(selection: anchor) { value in
                            onAnchor(value)
                        }
                        if let anchor {
                            Text(anchor.label)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                Text(sensitivity?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
            }
        }
    }

    private func optionRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: Theme.Space.s) { content() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.m) {
            if model.hasDIYPets || model.scope == .diy {
                scopePicker
            } else {
                Text("All Pets")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            searchField.frame(maxWidth: 260)
            addPetButton
        }
    }

    private var addPetButton: some View {
        Button {
            env.selectedSection = .diy
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .bold))
                Text("Make your own")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.accent.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Send photos of your pet and we'll turn it into a desktop companion"))
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search pets", text: $model.query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if model.isCatalogMissing {
            missingCatalogState
        } else if model.filtered.isEmpty {
            emptySearchState
        } else {
            let diyIDs = model.diyIDs
            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(model.filtered) { pet in
                    PetTile(pet: pet,
                            isPlaced: model.store.isActive(pet.slug),
                            isLocked: PetAccess.requiresPaywall(pet: pet, state: store.state, ownedIDs: model.submissions.unlockedPetIDs),
                            isDIY: diyIDs.contains(pet.remoteID ?? -1),
                            isSelected: model.focused?.slug == pet.slug)
                        .onTapGesture { withAnimation(Motion.transition) { model.select(pet) } }
                        .contextMenu {
                            Button {
                                place(pet)
                            } label: {
                                Label("Put on Desktop", systemImage: "pawprint.fill")
                            }
                            if model.store.isActive(pet.slug) {
                                Button(role: .destructive) {
                                    model.removeFromDesktop()
                                } label: {
                                    Label("Remove from Desktop", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .animation(Motion.reward, value: model.store.placement?.speciesSlug)
        }
    }

    private func place(_ pet: PetSpecies) {
        model.place(pet)
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(PetScope.allCases) { scope in
                let active = model.scope == scope
                Button {
                    model.scope = scope
                } label: {
                    HStack(spacing: 5) {
                        if scope == .diy {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(scope.label)
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.6)))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background {
                        if active { Capsule().fill(Theme.accent) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .liquidGlass(in: Capsule())
        .animation(Motion.hover, value: model.scope)
    }

    @ViewBuilder
    private var emptySearchState: some View {
        if model.scope == .diy && model.query.isEmpty {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                    .modifier(BreatheEffect())
                Text("No DIY pets yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Pets made from people's photos show up here.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                Button("Make your own") { env.selectedSection = .diy }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                    .padding(.top, Theme.Space.s)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "pawprint")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                    .modifier(BreatheEffect())
                Text("No pets found")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Try a different name.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private var missingCatalogState: some View {
        let remote = RemotePetService.shared
        return VStack(spacing: Theme.Space.m) {
            if remote.isRefreshing || remote.lastError == nil {
                ProgressView()
                    .controlSize(.large)
                Text("Loading pets…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Pets are downloaded once and kept on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Couldn't load pets")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(remote.lastError ?? "")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Try again") {
                    Task { await RemotePetService.shared.refresh() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 140)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct PetTile: View {
    let pet: PetSpecies
    let isPlaced: Bool
    var isLocked: Bool = false
    var isDIY: Bool = false
    var isSelected: Bool = false
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let image = PetPosterCache.image(for: pet.posterURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.top, 12)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .overlay { restingScrim }
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .topLeading) { placedBadge }
        .overlay(alignment: .topTrailing) {
            if isDIY {
                BadgePill(role: .type) { Text(verbatim: "DIY") }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    isPlaced ? Theme.accent.opacity(0.9)
                        : isSelected ? .white.opacity(0.75)
                        : .white.opacity(isHovering ? 0.16 : 0.06),
                    lineWidth: isPlaced || isSelected ? 2 : 1
                )
        }
        .scaleEffect(isHovering ? 1.025 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.35 : 0.12), radius: isHovering ? 16 : 6, y: isHovering ? 8 : 3)
        .animation(Motion.hover, value: isHovering)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(PetProfileStore.shared.displayName(for: pet))
    }

    private var restingScrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center)
    }

    private var caption: some View {
        Text(PetProfileStore.shared.displayName(for: pet))
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
            .padding(10)
    }

    @ViewBuilder
    private var placedBadge: some View {
        HStack(spacing: 0) {
            if isPlaced {
                BadgePill(role: .status) {
                    Text(verbatim: "ON DESKTOP")
                }
            }
            if isLocked {
                BadgePill(role: .status) {
                    Image(systemName: "lock.fill")
                    Text(verbatim: "PRO")
                }
            }
        }
    }
}

struct PetChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.07)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}


enum PetPosterCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}


struct PetProfileEditor: View {
    @Bindable var model: PetsViewModel
    let species: PetSpecies

    @State private var draft: PetProfile = .empty
    @State private var loadedSlug: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            field(String(localized: "Name"), text: $draft.displayName)
            field(String(localized: "Breed"), text: $draft.breed)
            field(String(localized: "Gender"), text: $draft.gender)
            field(String(localized: "Likes"), text: $draft.likes)
            field(String(localized: "Dislikes"), text: $draft.dislikes)

            HStack(alignment: .top, spacing: Theme.Space.s) {
                Text("Guardian")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 64, alignment: .leading)
                Text(model.guardianName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }

            Text("Pet Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            TextEditor(text: $draft.notes)
                .font(.caption)
                .scrollContentBackground(.hidden)
                .frame(height: 44)
                .padding(6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let failure = model.profiles.lastSaveError {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.yellow.opacity(0.9))
            }

            HStack {
                Spacer()
                Button("Reset to default") {
                    model.profiles.reset(species)
                    draft = model.profile(for: species)
                    model.updateProfile(draft, for: species)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(Theme.Space.s)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .onAppear(perform: load)
        .onChange(of: species.slug) { _, _ in load() }
        .onChange(of: draft) { _, new in
            guard loadedSlug == species.slug else { return }
            model.updateProfile(new, for: species)
        }
    }

    private func load() {
        model.profiles.clearSaveError()
        draft = model.profile(for: species)
        loadedSlug = species.slug
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 64, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}


struct PetPlacementPreview: View {
    let species: PetSpecies
    let size: PetSize
    let anchor: PetAnchor
    var sensitivity: PetSensitivity = .normal

    private var screenFrame: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
    }

    private var heightFactor: CGFloat {
        min(size.pointHeight / max(screenFrame.height, 1), 0.8)
    }

    var body: some View {
        GeometryReader { proxy in
            let mock = CGRect(origin: .zero, size: proxy.size)
            let subjectHeight = mock.height * heightFactor
            let petSize = CGSize(width: subjectHeight * species.aspectRatio / species.subjectHeight,
                                 height: subjectHeight)
            let rect = anchor.rect(for: petSize, in: mock, margin: 10)

            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.19, blue: 0.30),
                                        Color(red: 0.08, green: 0.09, blue: 0.15)],
                               startPoint: .top, endPoint: .bottom)
                PetPreviewView(species: species, sensitivity: sensitivity)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: mock.height - rect.midY)
                    .animation(Motion.reward, value: anchor)
                    .animation(Motion.reward, value: size)
                DesktopMenuBar()
            }
        }
        .aspectRatio(screenFrame.width / max(screenFrame.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }
}


struct DesktopMenuBar: View {
    static let height: CGFloat = 20
    var trailingInset: CGFloat = 12

    private static let lights: [Color] = [
        Color(red: 1.0, green: 0.37, blue: 0.34),
        Color(red: 1.0, green: 0.74, blue: 0.18),
        Color(red: 0.16, green: 0.78, blue: 0.25)
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Self.lights.indices, id: \.self) { index in
                Circle()
                    .fill(Self.lights[index])
                    .frame(width: 7, height: 7)
            }
            Spacer(minLength: 0)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Date(), style: .time)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.leading, 12)
        .padding(.trailing, trailingInset)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.35))
        .accessibilityHidden(true)
    }
}

struct PetPositionGrid: View {
    let selection: PetAnchor?
    let action: (PetAnchor) -> Void

    private static let cells: [[PetAnchor?]] = [
        [nil, nil, nil],
        [.leading, nil, .trailing],
        [.bottomLeading, .bottomCenter, .bottomTrailing]
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        cell(Self.cells[row][col])
                    }
                }
            }
        }
        .padding(5)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func cell(_ anchor: PetAnchor?) -> some View {
        if let anchor {
            Button {
                action(anchor)
            } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selection == anchor ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.10)))
                    .frame(width: 26, height: 20)
            }
            .buttonStyle(.plain)
            .help(anchor.label)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(0.03))
                .frame(width: 26, height: 20)
        }
    }
}
