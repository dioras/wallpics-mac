import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PetSubmitSheet: View {
    @Bindable var model: PetSubmissionModel
    let onClose: () -> Void

    @State private var dropTargeted = false

    private static let tips: [String] = [
        String(localized: "One pet per photo, front view plus a couple of angles works best"),
        String(localized: "Photos are only used to build your pet")
    ]

    var body: some View {
        Group {
            if case .done(let record) = model.phase {
                successState(record)
            } else {
                editingState
            }
        }
        .frame(width: 560)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(model.isUploading)
    }

    private var editingState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your pet")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Send 3–5 photos. We turn them into a desktop pet and add it to your list once it's approved (usually within 48 hours).")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            dropZone

            if !model.photoURLs.isEmpty {
                thumbnailRow
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.yellow.opacity(0.9))
            }

            if case .failed(let message) = model.phase {
                failureBanner(message)
            }

            tipList

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField(String(localized: "Name (optional)"), text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.notes)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .scrollContentBackground(.hidden)
                        .frame(height: 46)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    if model.notes.isEmpty {
                        Text("Anything we should know (optional)")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .disabled(model.isUploading)

            footer
        }
        .padding(Theme.Space.xl)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(dropTargeted ? Theme.accent.opacity(0.16) : Color.white.opacity(0.05))
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : Color.white.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
                Text("Drag photos here")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                Text("or click to choose from your Mac")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(height: 108)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !model.isUploading else { return }
            model.choosePhotos()
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.isUploading else { return false }
            loadDropped(providers)
            return true
        }
        .opacity(model.isUploading ? 0.5 : 1)
    }

    private var thumbnailRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(model.photoURLs, id: \.self) { url in
                        thumbnail(url)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("\(model.photoURLs.count) of \(PetSubmissionRules.maxPhotos)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func thumbnail(_ url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = model.thumbnails[url] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )

            Button {
                model.remove(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 17, height: 17)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .help(String(localized: "Remove photo"))
            .disabled(model.isUploading)
        }
    }

    private var tipList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Self.tips, id: \.self) { tip in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text(tip)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button("Try again") { model.retry() }
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

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if model.isUploading {
                ProgressView()
                    .controlSize(.small)
                Text("Uploading…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 120)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isUploading)
            Button("Submit") {
                Task { await model.submit() }
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: false))
            .frame(width: 140)
            .disabled(!model.canSubmit)
        }
    }

    private func successState(_ record: PetSubmissionRecord) -> some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Sent for review")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(record.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("It will appear in your pets once it's approved")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            Button("Done", action: onClose)
                .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                .frame(width: 140)
                .keyboardShortcut(.cancelAction)
                .padding(.top, Theme.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxxl)
        .padding(.horizontal, Theme.Space.xl)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let identifier = UTType.fileURL.identifier
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(identifier) }
        Task { @MainActor in
            var resolved: [URL] = []
            var failures = 0
            for provider in candidates {
                do {
                    let item = try await provider.loadItem(forTypeIdentifier: identifier)
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        resolved.append(url)
                    } else if let url = item as? URL {
                        resolved.append(url)
                    } else {
                        failures += 1
                    }
                } catch {
                    failures += 1
                    Log.ui.error("PetSubmitSheet: dropped item could not be read — \(error.localizedDescription, privacy: .public)")
                }
            }
            model.addPhotos(resolved)
            if failures > 0, model.notice == nil {
                model.notice = String(localized: "Some dropped items couldn't be read and were skipped.")
            }
        }
    }
}

enum PetSubmissionThumbnails {
    private static let maxPixel = 120

    static func image(for url: URL) -> NSImage? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

#Preview {
    PetSubmitSheet(model: PetSubmissionModel(), onClose: {})
}
