import SwiftUI

/// Adaptive editor for any widget kind. Left: a live, tappable preview rendered by the same
/// `WidgetRenderView` used on the desktop. Right: the controls relevant to the kind (photos,
/// family, name, polaroid styling). Presented as a sheet from the gallery / My Widgets.
struct WidgetEditorView: View {
    @State var model: WidgetEditorModel
    /// Called with the saved instance so the caller can offer "Place on Desktop".
    var onSaved: (WidgetInstance) -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                previewColumn
                    .frame(width: 280)
                ScrollView { controlsColumn.padding(.trailing, Theme.Space.xs) }
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Space.xl)
            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .background(AmbientBackdrop())
        .task { await model.prepare() }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Image(systemName: model.instance.kind.symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
            Text(model.title).font(.title3.weight(.semibold))
            Spacer()
            if model.isPreparing { ProgressView().controlSize(.small) }
        }
        .padding(Theme.Space.l)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if let err = model.prepareError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
            Button("Save Widget") {
                let saved = model.save()
                onSaved(saved)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSave)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Space.l)
    }

    // MARK: - Preview

    private var previewColumn: some View {
        VStack(spacing: Theme.Space.m) {
            let size = previewSize
            WidgetRenderView(instance: model.instance, isToggled: model.previewToggle, carouselStep: model.previewStep)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard model.instance.kind.isInteractive else { return }
                    if model.instance.kind == .polaroid {
                        model.previewStep += 1   // PolaroidBody animates the slot change itself
                    } else {
                        withAnimation(.easeOut(duration: 0.55)) { model.previewToggle.toggle() }
                    }
                }

            if model.instance.kind.isInteractive {
                Label(model.instance.kind == .polaroid ? "Tap the preview to flip through photos" : "Tap the preview to see it open",
                      systemImage: "hand.tap")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var previewSize: CGSize {
        // `aspectRatio` is width/height: 1 for small/large (square), 2 for medium (2:1).
        let maxW: CGFloat = 240
        let ar = model.instance.family.aspectRatio
        return CGSize(width: maxW, height: maxW / ar)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            nameField
            if model.instance.kind.supportedFamilies.count > 1 { familyPicker }
            photoControls
            if model.instance.kind == .polaroid { polaroidControls }
            Spacer(minLength: 0)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Widget name", text: $model.instance.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var familyPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Size").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Size", selection: Binding(
                get: { model.instance.family },
                set: { model.setFamily($0) }
            )) {
                ForEach(model.instance.kind.supportedFamilies) { fam in
                    Text(fam.label).tag(fam)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var photoControls: some View {
        switch model.instance.kind {
        case .staticImage, .template:
            EmptyView() // image comes from the backend bundle
        case .polaroid, .photo:
            multiPhotoControls
        default:
            singlePhotoControls
        }
    }

    private var singlePhotoControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Photo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                thumbStrip
                Button {
                    model.addPhotos(multiple: false)
                } label: {
                    Label(model.photoRelativePaths.isEmpty ? "Choose Photo" : "Replace", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var multiPhotoControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(model.instance.kind == .polaroid ? "Photos (carousel)" : "Photos")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.addPhotos(multiple: true)
                } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if model.instance.kind == .photo {
                Toggle("Fill (crop to fit)", isOn: Binding(
                    get: { model.instance.payload.photoFill },
                    set: { model.setFill($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            thumbStrip
        }
    }

    private var thumbStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(model.photoRelativePaths.enumerated()), id: \.offset) { idx, rel in
                    let url = WidgetStore.shared.assetURL(for: rel, in: model.instance.id)
                    ZStack(alignment: .topTrailing) {
                        ThumbnailView(url: url, cornerRadius: Theme.Radius.control)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                        Button {
                            model.removePhoto(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                    }
                }
            }
        }
        .frame(height: 60)
    }

    private var polaroidControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Background").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: Theme.Space.s) {
                bgChip("Clear", isOn: isTransparent) { model.setPolaroidBackground(.transparent) }
                bgChip("Dark", isOn: isColor) { model.setPolaroidBackground(.color(hexes: ["#1c1c1e", "#3a3a3c"])) }
            }
        }
    }

    private func bgChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                .background(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var isTransparent: Bool {
        if case .polaroid(let s) = model.instance.payload, case .transparent = s.background { return true }
        return false
    }
    private var isColor: Bool {
        if case .polaroid(let s) = model.instance.payload, case .color = s.background { return true }
        return false
    }
}
