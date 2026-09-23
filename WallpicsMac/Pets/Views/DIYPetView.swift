import SwiftUI

struct DIYPetView: View {
    @Bindable var model: PetsViewModel
    @Environment(StoreKitService.self) private var store
    @Environment(AppEnvironment.self) private var env

    private static let sideBySideMinWidth: CGFloat = 1100
    private static let formColumnWidth: CGFloat = 560
    private let stepColumns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: Theme.Space.m)]

    private var locked: Bool { PetAccess.submissionsRequirePro(state: store.state) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header
                    if geo.size.width >= Self.sideBySideMinWidth {
                        HStack(alignment: .top, spacing: Theme.Space.xl) {
                            formCard
                                .frame(width: Self.formColumnWidth)
                            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                                yourPetsSection
                                howItWorks
                                submissionsSection
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        yourPetsSection
                        howItWorks
                        formCard
                        submissionsSection
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .scrollContentBackground(.hidden)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .onAppear {
            model.submissionSync.refreshNow()
            model.submissions.markReadySeen()
        }
        .onChange(of: model.submissions.unseenReady.count) { _, count in
            if count > 0, PetReadyCenter.isAppInFront { model.submissions.markReadySeen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.async {
                if PetReadyCenter.isAppInFront { model.submissions.markReadySeen() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DIY Pet")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("Send a few photos of your pet. We turn them into a desktop companion that follows your cursor — just like the ones in Pets.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            Spacer()
            if locked {
                Button { PaywallPresenter.show() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Part of WallPics Pro")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.accent.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "WallPics Pro unlocks custom pets"))
            }
        }
        .padding(.top, Theme.Space.xl)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("How it works")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            LazyVGrid(columns: stepColumns, alignment: .leading, spacing: Theme.Space.m) {
                StepCard(number: 1, symbol: "photo.on.rectangle.angled",
                         title: String(localized: "Send 1–5 photos"),
                         detail: String(localized: "Clear, well-lit shots of one pet — a front view plus a couple of angles."))
                StepCard(number: 2, symbol: "sparkles",
                         title: String(localized: "We build it"),
                         detail: String(localized: "A person checks the photos, then our pipeline animates your pet so it can look around. Usually within 48 hours."))
                StepCard(number: 3, symbol: "pawprint.fill",
                         title: String(localized: "It joins your Pets"),
                         detail: String(localized: "It appears in the Pets tab and we notify you. Put it on your desktop like any other pet."))
            }
        }
    }

    @ViewBuilder
    private var yourPetsSection: some View {
        let pets = model.ownReadySpecies
        if !pets.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your pets")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("Also in Pets → DIY")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: Theme.Space.m)],
                          alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(pets) { pet in
                        PetTile(pet: pet,
                                isPlaced: model.store.isActive(pet.slug),
                                isLocked: PetAccess.requiresPaywall(pet: pet, state: store.state),
                                isDIY: true)
                            .onTapGesture {
                                model.select(pet)
                                env.selectedSection = .pets
                            }
                            .contextMenu {
                                Button {
                                    model.place(pet)
                                } label: {
                                    Label("Put on Desktop", systemImage: "pawprint.fill")
                                }
                            }
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Send your photos")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if locked {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(verbatim: "PRO")
                    }
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white, in: Capsule(style: .continuous))
                }
            }
            PetSubmissionForm(
                model: model.submission,
                locked: locked,
                onLockedSubmit: { PaywallPresenter.show() },
                onReset: { model.submission.reset() }
            )
        }
        .padding(Theme.Space.l)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var submissionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text("Your submissions")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if !model.submissions.inReview.isEmpty {
                    checkNowButton
                }
            }

            if let error = model.submissionSync.lastError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.yellow.opacity(0.9))
            }

            if model.submissions.records.isEmpty {
                Text("Nothing sent yet. Your pets show up here while we build them.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.vertical, Theme.Space.s)
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(model.submissions.records) { record in
                        SubmissionRow(record: record,
                                      onShowInPets: { showInPets(record) },
                                      onRemove: { model.submissions.remove(id: record.id) })
                    }
                }
                .animation(Motion.transition, value: model.submissions.records)
            }
        }
    }

    private var checkNowButton: some View {
        Button {
            model.submissionSync.refreshNow(force: true)
        } label: {
            HStack(spacing: 6) {
                if model.submissionSync.isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(model.submissionSync.isChecking ? "Checking…" : "Check now")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Capsule())
        .disabled(model.submissionSync.isChecking)
        .help(lastCheckedHint)
    }

    private var lastCheckedHint: String {
        guard let date = model.submissionSync.lastCheckedAt else {
            return String(localized: "We check every 10 minutes while WallPics is open")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return String(localized: "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))")
    }

    private func showInPets(_ record: PetSubmissionRecord) {
        if let slug = record.catalogSlug, let species = PetCatalog.species(slug: slug) {
            model.query = model.displayName(for: species)
        } else {
            model.query = ""
        }
        model.scope = .diy
        env.selectedSection = .pets
    }
}

private struct StepCard: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(verbatim: "\(number)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(.white, in: Circle())
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(Theme.Space.m)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SubmissionRow: View {
    let record: PetSubmissionRecord
    let onShowInPets: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            statusGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            statusPill
            if record.status == .ready {
                Button("Show in Pets", action: onShowInPets)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .foregroundStyle(.black)
                    .background(.white, in: Capsule())
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(isHovering ? 0.12 : 0.0), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(canDismiss ? 1 : 0)
            .disabled(!canDismiss)
            .help(String(localized: "Remove from list"))
        }
        .padding(Theme.Space.m)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(record.status == .ready ? Theme.accent.opacity(0.6) : .white.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            if record.status == .ready {
                Button("Show in Pets", action: onShowInPets)
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove from list", systemImage: "trash")
            }
        }
    }

    private var canDismiss: Bool { record.status != .inReview || record.isOverdue() }

    private var subtitle: String {
        switch record.status {
        case .inReview where record.isOverdue():
            return String(localized: "Sent \(record.submittedAt.formatted(date: .abbreviated, time: .omitted)) · taking longer than usual. Still waiting to hear back — you can remove it or send the photos again.")
        case .inReview:
            return String(localized: "Sent \(record.submittedAt.formatted(date: .abbreviated, time: .omitted)) · \(record.photoCount) photos · usually ready within 48 hours")
        case .ready:
            return String(localized: "Ready — find it in the Pets tab")
        case .rejected:
            return record.rejectionReason ?? String(localized: "We couldn't build a pet from these photos. Try clearer shots of one pet.")
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        Group {
            switch record.status {
            case .inReview:
                Image(systemName: "hourglass")
                    .foregroundStyle(.white.opacity(0.7))
                    .modifier(BreatheEffect())
            case .ready:
                Image(systemName: "checkmark")
                    .foregroundStyle(.black)
            case .rejected:
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 13, weight: .bold))
        .frame(width: 34, height: 34)
        .background(glyphBackground, in: Circle())
    }

    private var glyphBackground: AnyShapeStyle {
        switch record.status {
        case .inReview: return AnyShapeStyle(Color.white.opacity(0.08))
        case .ready: return AnyShapeStyle(Theme.accent)
        case .rejected: return AnyShapeStyle(Color.yellow.opacity(0.35))
        }
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(record.status == .ready ? .black : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(record.status == .ready ? AnyShapeStyle(.white) : AnyShapeStyle(Color.white.opacity(0.12)),
                        in: Capsule(style: .continuous))
    }

    private var statusLabel: String {
        switch record.status {
        case .inReview: return String(localized: "IN REVIEW")
        case .ready: return String(localized: "READY")
        case .rejected: return String(localized: "NOT BUILT")
        }
    }
}

#Preview {
    DIYPetView(model: PetsViewModel())
        .environment(StoreKitService.shared)
        .environment(AppEnvironment.shared)
        .frame(width: 1240, height: 820)
}
