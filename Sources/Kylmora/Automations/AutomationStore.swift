import Foundation

/// The rules as one JSON file, beside the routing rules and for the same
/// reason: configuration, not session state.
struct AutomationStore {
    let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "automations.json")) {
        self.fileURL = fileURL
    }

    /// A missing or unreadable file is no rules, which is the feature off.
    func load() -> AutomationRules {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode(AutomationRules.self, from: data) else {
            return .empty
        }
        return rules.discardingEmptyRules()
    }

    func save(_ rules: AutomationRules) throws {
        AppPaths.ensureSupportDirectory()
        try data(for: rules).write(to: fileURL, options: [.atomic])
    }

    /// The rules as the file holds them, for export.
    func data(for rules: AutomationRules) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rules.discardingEmptyRules())
    }

    static func rules(from data: Data) throws -> AutomationRules {
        try JSONDecoder().decode(AutomationRules.self, from: data).discardingEmptyRules()
    }
}
