import SwiftUI

struct UploadsView: View {
    @Bindable var model: BrowseViewModel
    @Environment(AppEnvironment.self) private var env

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: Theme.Space.l)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if model.imported.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .task { await model.loadImports() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Uploads")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text(model.imported.isEmpty
                     ? String(localized: "Bring your own images, videos, GIFs or shaders.")
                     : String(localized: "\(model.imported.count) wallpapers ready to use."))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            uploadButton
        }
        .padding(.top, Theme.Space.xl)
    }

    private var uploadButton: some View {
        Button(action: importWallpaper) {
            HStack(spacing: 7) {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                Text("Upload")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(.black)
            .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isImporting)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.l) {
            ForEach(model.imported) { wallpaper in
                WallpaperCard(wallpaper: wallpaper, isSelected: env.selectedWallpaper?.id == wallpaper.id)
                    .onTapGesture {
                        withAnimation(Motion.transition) {
                            env.selectedWallpaper = wallpaper
                            env.selectedSection = .browse
                        }
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
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(Motion.reward, value: model.imported.map(\.id))
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                    .fill(.white.opacity(0.04))
                RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                        .modifier(BreatheEffect())
                    Text("Make any file your wallpaper")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Photos, videos, GIFs, Metal shaders and Rive animations — they all work, watermark-free with Pro.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    uploadButton
                        .padding(.top, Theme.Space.s)
                }
                .padding(Theme.Space.xxl)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .padding(.top, Theme.Space.l)
    }

    private func importWallpaper() {
        Task {
            if let wp = await model.importWallpaper() {
                withAnimation(Motion.transition) {
                    env.selectedWallpaper = wp
                    env.selectedSection = .browse
                }
            }
        }
    }
}
