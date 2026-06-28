import AppIntents
import WidgetKit

struct WidgetEntity: AppEntity, Identifiable {
    let id: String
    let name: String
    let kindName: String

    init(id: String, name: String, kindName: String) {
        self.id = id
        self.name = name
        self.kindName = kindName
    }

    init(shared: SharedWidget) {
        self.id = shared.id
        self.name = shared.displayName
        self.kindName = shared.displayKind
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "WallPics Widget")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kindName)")
    }

    static var defaultQuery = WidgetEntityQuery()
}

struct WidgetEntityQuery: EntityQuery {
    func entities(for identifiers: [WidgetEntity.ID]) async throws -> [WidgetEntity] {
        WidgetSharedStore.shared.allWidgets()
            .filter { identifiers.contains($0.id) }
            .map(WidgetEntity.init(shared:))
    }

    func suggestedEntities() async throws -> [WidgetEntity] {
        WidgetSharedStore.shared.allWidgets().map(WidgetEntity.init(shared:))
    }

    func defaultResult() async -> WidgetEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Widget"
    static var description = IntentDescription("Pick which of your WallPics widgets to display.")

    @Parameter(title: "Widget")
    var selected: WidgetEntity?

    init() {}

    init(selected: WidgetEntity?) {
        self.selected = selected
    }
}
