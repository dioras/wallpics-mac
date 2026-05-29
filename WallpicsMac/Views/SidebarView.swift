import SwiftUI

struct SidebarView: View {
    @Binding var selection: AppEnvironment.Section
    @Environment(StoreKitService.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(AppEnvironment.Section.allCases) { section in
                        Label(section.label, systemImage: section.symbol)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)

            if !store.state.isPro {
                GoProPill()
                    .padding(Theme.Space.m)
            }
        }
    }
}

private struct GoProPill: View {
    @State private var hovering = false
    var body: some View {
        Button { PaywallPresenter.show() } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Go Pro").font(.callout.weight(.semibold))
                    Text("Remove watermark").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.accent.opacity(hovering ? 0.22 : 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}
