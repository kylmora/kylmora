import Foundation

/// The rules as one JSON file, beside the routing rules and for the same
/// reason: configuration, not session state.
struct AutomationStore {
    private let file: JSONFile<AutomationRules>
    var fileURL: URL { file.url }

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "automations.json")) {
        file = JSONFile(fileURL)
    }

    /// A missing or unreadable file is no rules, which is the feature off.
    func load() -> AutomationRules {
        (file.load() ?? .empty).discardingEmptyRules()
    }

    func save(_ rules: AutomationRules) throws {
        try file.save(rules.discardingEmptyRules())
    }

    /// The rules as the file holds them, for export.
    func data(for rules: AutomationRules) throws -> Data {
        try JSONFile<AutomationRules>.encode(rules.discardingEmptyRules())
    }

    static func rules(from data: Data) throws -> AutomationRules {
        try JSONFile<AutomationRules>.decode(data).discardingEmptyRules()
    }
}
