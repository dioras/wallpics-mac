import SwiftUI

struct PetsView: View {
    @Bindable var model: PetsViewModel

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: Theme.Space.l)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if let active = model.active {
                    activePetCard(active)
                }
                toolbar
                content
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
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

    private func activePetCard(_ pet: PetSpecies) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            PetPlacementPreview(
                species: pet,
                size: model.store.placement?.size ?? .medium,
                anchor: model.store.placement?.anchor ?? .bottomTrailing
            )
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pet.name)
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

                optionRow(title: String(localized: "Size")) {
                    ForEach(PetSize.allCases) { size in
                        PetChip(title: size.label, isSelected: model.store.placement?.size == size) {
                            model.setSize(size)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Position")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: Theme.Space.m) {
                        PetPositionGrid(selection: model.store.placement?.anchor) { anchor in
                            model.setAnchor(anchor)
                        }
                        if let anchor = model.store.placement?.anchor {
                            Text(anchor.label)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }

                optionRow(title: String(localized: "Sensitivity")) {
                    ForEach(PetSensitivity.allCases) { level in
                        PetChip(title: level.label,
                                isSelected: model.store.placement?.sensitivity == level) {
                            model.setSensitivity(level)
                        }
                    }
                }

                Text(model.store.placement?.sensitivity.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))

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
                    .help(String(localized: "Remove \(pet.name) from Desktop"))
                }
            }
            .frame(width: 340, alignment: .leading)
        }
        .padding(Theme.Space.l)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
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
            Text("All Pets")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            searchField.frame(maxWidth: 260)
        }
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
            LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                ForEach(model.filtered) { pet in
                    PetTile(pet: pet, isPlaced: model.store.isActive(pet.slug))
                        .onTapGesture { model.place(pet) }
                        .contextMenu {
                            Button {
                                model.place(pet)
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

    private var emptySearchState: some View {
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

    private var missingCatalogState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("Pet pack unavailable")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("The bundled pets could not be read. Reinstalling WallPics restores them.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct PetTile: View {
    let pet: PetSpecies
    let isPlaced: Bool
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    isPlaced ? Theme.accent.opacity(0.9) : .white.opacity(isHovering ? 0.16 : 0.06),
                    lineWidth: isPlaced ? 2 : 1
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
        .help(pet.name)
    }

    private var restingScrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center)
    }

    private var caption: some View {
        Text(pet.name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
            .padding(10)
    }

    @ViewBuilder
    private var placedBadge: some View {
        if isPlaced {
            BadgePill(role: .status) {
                Text(verbatim: "ON DESKTOP")
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

    private var screenFrame: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
    }

    private var heightFactor: CGFloat {
        switch size {
        case .small: return 0.42
        case .medium: return 0.56
        case .large: return 0.72
        }
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
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 5)
                PetPreviewView(species: species)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: mock.height - rect.midY)
                    .animation(Motion.reward, value: anchor)
                    .animation(Motion.reward, value: size)
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
