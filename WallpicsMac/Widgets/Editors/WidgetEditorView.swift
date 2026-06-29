import SwiftUI
import UniformTypeIdentifiers

struct WidgetEditorView: View {
    @State var model: WidgetEditorModel
    var onSaved: (WidgetInstance) -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false
    @State private var dragStart: CGPoint?

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
            .buttonStyle(PrimaryButtonStyle(fullWidth: false))
            .disabled(!model.canSave)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Space.l)
    }

    private var previewColumn: some View {
        VStack(spacing: Theme.Space.m) {
            let size = previewSize
            preview(size: size)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

            if showsReposition {
                Label("Drag the preview to reposition", systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.instance.kind.isInteractive {
                Label(model.instance.kind == .polaroid ? "Tap the preview to flip through photos" : "Tap the preview to see it open",
                      systemImage: "hand.tap")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func preview(size: CGSize) -> some View {
        let base = WidgetRenderView(instance: model.instance, isToggled: model.previewToggle, carouselStep: model.previewStep)
            .contentShape(Rectangle())
        if showsReposition {
            base.gesture(repositionGesture(size: size))
        } else if model.instance.kind.isInteractive {
            base.onTapGesture {
                if model.instance.kind == .polaroid {
                    model.previewStep += 1
                } else {
                    withAnimation(.easeOut(duration: 0.55)) { model.previewToggle.toggle() }
                }
            }
        } else {
            base
        }
    }

    private func repositionGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if dragStart == nil { dragStart = model.instance.payload.focalOffset }
                let base = dragStart ?? .zero
                let nx = base.x + (v.translation.width / max(size.width, 1)) * 2
                let ny = base.y + (v.translation.height / max(size.height, 1)) * 2
                model.setFocalOffset(x: nx, y: ny)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var showsReposition: Bool {
        switch model.instance.payload {
        case .photo(let s): return s.fill && !s.relativePaths.isEmpty
        case .video(let s): return s.fill && !s.relativePath.isEmpty
        default: return false
        }
    }

    private var previewSize: CGSize {
        let maxW: CGFloat = 240
        let ar = model.instance.family.aspectRatio
        return CGSize(width: maxW, height: maxW / ar)
    }

    @ViewBuilder
    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            nameField
            if model.instance.kind.supportedFamilies.count > 1 { familyPicker }
            photoControls
            if model.instance.kind == .polaroid { polaroidControls }
            if model.instance.kind == .dateTime { dateTimeControls }
            Spacer(minLength: 0)
        }
    }

    private var dateTimeControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Style").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Style", selection: Binding(
                    get: { model.dateTimeState.style },
                    set: { model.setClockStyle($0) }
                )) {
                    Text("Time").tag(DateTimeWidgetState.Style.time)
                    Text("Date").tag(DateTimeWidgetState.Style.date)
                    Text("Both").tag(DateTimeWidgetState.Style.timeAndDate)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Background").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Array(WidgetClockStyle.backgroundChoices.enumerated()), id: \.offset) { _, hexes in
                            let selected = model.dateTimeState.backgroundHexes == hexes
                            Circle()
                                .fill(WidgetClockStyle.gradient(hexes))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
                                .onTapGesture { model.setClockBackground(hexes) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Text color").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.s) {
                    ForEach(WidgetClockStyle.tintChoices, id: \.self) { hex in
                        let selected = model.dateTimeState.tintHex == hex
                        Circle()
                            .fill(Color(hex: hex) ?? .white)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                            .overlay(Circle().strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
                            .onTapGesture { model.setClockTint(hex) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Font").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Font", selection: Binding(
                    get: { model.dateTimeState.fontKey },
                    set: { model.setClockFont($0) }
                )) {
                    Text("Rounded").tag("rounded")
                    Text("Classic").tag("default")
                    Text("Serif").tag("serif")
                    Text("Mono").tag("mono")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Toggle("24-hour time", isOn: Binding(
                get: { model.dateTimeState.use24Hour },
                set: { model.setClock24Hour($0) }
            ))
            .toggleStyle(.checkbox).font(.caption)
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
        case .staticImage, .template, .dateTime:
            EmptyView()
        case .video:
            videoControls
        case .polaroid, .photo:
            multiPhotoControls
        default:
            singlePhotoControls
        }
    }

    private var mediaDropZone: some View {
        let isVideo = model.instance.kind == .video
        return ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(dropTargeted ? Theme.accent.opacity(0.16) : Color.secondary.opacity(0.08))
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 6) {
                Image(systemName: isVideo ? "video.badge.plus" : "photo.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                Text(isVideo ? "Drag a video here" : "Drag a photo here")
                    .font(.callout.weight(.medium))
                Text("or click to choose from your Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 116)
        .contentShape(Rectangle())
        .onTapGesture { isVideo ? model.addVideo() : model.addPhotos(multiple: model.instance.kind == .photo) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importDropped(url: url) }
            }
            return true
        }
    }

    private var fillBinding: Binding<Bool> {
        Binding(get: { model.instance.payload.videoFill }, set: { model.setFill($0) })
    }

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Video").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            mediaDropZone
            Toggle("Fill (crop to fit)", isOn: fillBinding)
                .toggleStyle(.checkbox).font(.caption)
            if model.videoAssetURL != nil {
                Label("Plays muted, on loop, on your desktop", systemImage: "infinity")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var singlePhotoControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Photo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            mediaDropZone
            thumbStrip
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
            mediaDropZone
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
