import Foundation
import Security

/// The wire format a model speaks.
enum AssistantAPIFormat: String, Codable, CaseIterable, Sendable {
    /// Anthropic's Messages API.
    case anthropic
    /// The OpenAI Chat Completions format, which OpenAI, OpenRouter, Groq,
    /// Ollama, LM Studio and most other servers accept.
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI-compatible"
        }
    }
}

/// A model the assistant can talk to: which server, in which format, under
/// which model name. The built-in Claude models are here from the start; the
/// user adds anything else.
struct AssistantModelConfig: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var format: AssistantAPIFormat
    var baseURL: String
    var model: String
    var isBuiltIn = false

    /// Servers that need no key (a model running on this Mac).
    var isLocal: Bool {
        guard let host = URL(string: baseURL)?.host() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// The Keychain entry for this model's key. Shared by every model on the
    /// same server, so one OpenAI key covers every OpenAI model.
    var keyAccount: String {
        let host = URL(string: baseURL)?.host() ?? baseURL
        // The name the first build stored the Anthropic key under.
        return host == "api.anthropic.com" ? "anthropic-api-key" : "key:\(host)"
    }
}

/// A starting point when adding a model.
struct AssistantProviderPreset: Sendable {
    let name: String
    let format: AssistantAPIFormat
    let baseURL: String
    let modelHint: String
    let keyURL: String?

    static let all: [AssistantProviderPreset] = [
        .init(name: "Anthropic", format: .anthropic, baseURL: "https://api.anthropic.com/v1", modelHint: "claude-opus-5-5", keyURL: "https://console.anthropic.com/settings/keys"),
        .init(name: "OpenAI", format: .openai, baseURL: "https://api.openai.com/v1", modelHint: "Model ID from your OpenAI account", keyURL: "https://platform.openai.com/api-keys"),
        .init(name: "OpenRouter", format: .openai, baseURL: "https://openrouter.ai/api/v1", modelHint: "provider/model", keyURL: "https://openrouter.ai/keys"),
        .init(name: "Groq", format: .openai, baseURL: "https://api.groq.com/openai/v1", modelHint: "Model ID from Groq", keyURL: "https://console.groq.com/keys"),
        .init(name: "Ollama (this Mac)", format: .openai, baseURL: "http://localhost:11434/v1", modelHint: "e.g. llama3.1", keyURL: nil),
        .init(name: "LM Studio (this Mac)", format: .openai, baseURL: "http://localhost:1234/v1", modelHint: "Model loaded in LM Studio", keyURL: nil),
        .init(name: "Custom", format: .openai, baseURL: "https://", modelHint: "Model ID", keyURL: nil),
    ]
}

/// The user's models, the one in use, and their keys.
@MainActor
enum AssistantConfigStore {
    private static let modelsKey = "AssistantModels"
    private static let selectedKey = "AssistantSelectedModel"
    private static let keychainService = "com.kylmora.assistant"

    static let builtIns: [AssistantModelConfig] = [
        .init(id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000001")!, name: "Claude Opus 5.5", format: .anthropic,
              baseURL: "https://api.anthropic.com/v1", model: "claude-opus-5-5", isBuiltIn: true),
        .init(id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000002")!, name: "Claude Sonnet 5.5", format: .anthropic,
              baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-5-5", isBuiltIn: true),
        .init(id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000003")!, name: "Claude Haiku 5.5", format: .anthropic,
              baseURL: "https://api.anthropic.com/v1", model: "claude-haiku-5-5", isBuiltIn: true),
    ]

    static var defaults: UserDefaults = .standard

    /// The models the user added.
    static var customModels: [AssistantModelConfig] {
        get {
            guard let data = defaults.data(forKey: modelsKey),
                  let models = try? JSONDecoder().decode([AssistantModelConfig].self, from: data) else { return [] }
            return models
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: modelsKey)
            NotificationCenter.default.post(name: .assistantModelsDidChange, object: nil)
        }
    }

    static var allModels: [AssistantModelConfig] { builtIns + customModels }

    static var selected: AssistantModelConfig {
        get {
            let id = defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
            return allModels.first { $0.id == id } ?? builtIns[0]
        }
        set {
            defaults.set(newValue.id.uuidString, forKey: selectedKey)
            NotificationCenter.default.post(name: .assistantModelsDidChange, object: nil)
        }
    }

    static func save(_ model: AssistantModelConfig) {
        var models = customModels
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        } else {
            models.append(model)
        }
        customModels = models
    }

    static func remove(_ model: AssistantModelConfig) {
        customModels = customModels.filter { $0.id != model.id }
        if selected.id == model.id { selected = builtIns[0] }
    }

    // MARK: - Keys, in the Keychain

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    static func key(for model: AssistantModelConfig) -> String? {
        var query = query(model.keyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func setKey(_ key: String, for model: AssistantModelConfig) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SecItemDelete(query(model.keyAccount) as CFDictionary)
            return true
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(model.keyAccount) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query(model.keyAccount)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Kylmora Assistant key (\(URL(string: model.baseURL)?.host() ?? model.baseURL))"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Whether the model can be used as it stands: a key, unless it runs locally.
    static func isReady(_ model: AssistantModelConfig) -> Bool {
        model.isLocal || key(for: model) != nil
    }
}

extension Notification.Name {
    static let assistantModelsDidChange = Notification.Name("com.kylmora.assistant.modelsDidChange")
}
