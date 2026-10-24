import Foundation
import Network

/// A lightweight, embedded HTTP and JSON-RPC / MCP server that runs inside Kylmora
/// on loopback (`127.0.0.1`), allowing terminal AI agents and external CLI tools
/// to control the browser with humanized actions.
public final class AgentServer: @unchecked Sendable {
    public static let shared = AgentServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kylmora.agent.server", qos: .userInitiated)
    public private(set) var port: UInt16 = 0
    public private(set) var token: String = ""

    private init() {}

    /// Starts the server and publishes `agent-runtime.json`.
    @MainActor
    func start(session: BrowserSession? = nil) {
        AgentController.shared.session = session
        guard listener == nil else { return }

        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        port = 4999
        publishRuntimeConfig()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Try default port 4999 first; if unavailable, use ephemeral port 0
        let targetPort: NWEndpoint.Port = NWEndpoint.Port(rawValue: 4999) ?? .any

        do {
            let listener = try NWListener(using: parameters, on: targetPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let portValue = listener.port?.rawValue {
                        self.port = portValue
                        self.publishRuntimeConfig()
                    }
                case .failed(let error):
                    NSLog("Kylmora AgentServer failed: \(error)")
                    // Retry on any ephemeral port if default was busy
                    if targetPort != .any {
                        self.retryWithEphemeralPort(parameters: parameters)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: queue)
        } catch {
            NSLog("Kylmora AgentServer start error: \(error)")
        }
    }

    private func retryWithEphemeralPort(parameters: NWParameters) {
        listener?.cancel()
        listener = nil
        do {
            let fallbackListener = try NWListener(using: parameters, on: .any)
            self.listener = fallbackListener
            fallbackListener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let portValue = fallbackListener.port?.rawValue {
                    self?.port = portValue
                    self?.publishRuntimeConfig()
                }
            }
            fallbackListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            fallbackListener.start(queue: queue)
        } catch {
            NSLog("Kylmora AgentServer fallback start error: \(error)")
        }
    }

    /// Stops the server and removes runtime discovery files.
    public func stop() {
        listener?.cancel()
        listener = nil
        removeRuntimeConfig()
    }

    // MARK: - Discovery Configuration

    private func publishRuntimeConfig() {
        let config: [String: Any] = [
            "port": Int(port),
            "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": "1.0.0",
            "url": "http://127.0.0.1:\(port)"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) else { return }

        // Write to App Support
        let appSupportFile = AppPaths.supportDirectory.appending(path: "agent-runtime.json")
        try? data.write(to: appSupportFile, options: .atomic)

        // Write to ~/.kylmora/agent-runtime.json for convenient user/tool access
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let dotKylmora = userHome.appending(path: ".kylmora", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dotKylmora, withIntermediateDirectories: true)
        let dotRuntimeFile = dotKylmora.appending(path: "agent-runtime.json")
        try? data.write(to: dotRuntimeFile, options: .atomic)
    }

    private func removeRuntimeConfig() {
        let appSupportFile = AppPaths.supportDirectory.appending(path: "agent-runtime.json")
        try? FileManager.default.removeItem(at: appSupportFile)

        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let dotRuntimeFile = userHome.appending(path: ".kylmora/agent-runtime.json")
        try? FileManager.default.removeItem(at: dotRuntimeFile)
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPRequest(connection: connection, accumulated: Data())
    }

    private func readHTTPRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var data = accumulated
            if let content {
                data.append(content)
            }

            if let requestString = String(data: data, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                // Headers complete; check Content-Length
                let headerText = String(requestString[..<headerEndRange.lowerBound])
                let bodyStartIndex = data.index(data.startIndex, offsetBy: headerText.utf8.count + 4)
                let bodyData = data.subdata(in: bodyStartIndex..<data.endIndex)

                var contentLength = 0
                for line in headerText.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let parts = line.split(separator: ":")
                        if parts.count > 1, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                            contentLength = len
                        }
                    }
                }

                if bodyData.count >= contentLength {
                    // Full request received
                    self.dispatchHTTPRequest(headerText: headerText, body: bodyData, connection: connection)
                    return
                }
            }

            if !isComplete && error == nil {
                self.readHTTPRequest(connection: connection, accumulated: data)
            } else {
                connection.cancel()
            }
        }
    }

    private func dispatchHTTPRequest(headerText: String, body: Data, connection: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(status: 400, body: "Bad Request", connection: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(status: 400, body: "Bad Request", connection: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }

        // Public health endpoint
        if method == "GET" && (path == "/health" || path == "/") {
            let res = ["status": "ok", "app": "Kylmora", "version": "1.0.0"]
            let json = (try? JSONSerialization.data(withJSONObject: res)) ?? Data()
            sendHTTPResponse(status: 200, contentType: "application/json", bodyData: json, connection: connection)
            return
        }

        // Authentication check for control routes
        let authHeader = headers["authorization"] ?? ""
        let tokenHeader = headers["x-kylmora-token"] ?? ""
        let tokenValid = (authHeader == "Bearer \(token)") || (tokenHeader == token)

        guard tokenValid else {
            let errorJson = ["error": "Unauthorized", "message": "Valid Bearer token required in Authorization or X-Kylmora-Token header."]
            let data = (try? JSONSerialization.data(withJSONObject: errorJson)) ?? Data()
            sendHTTPResponse(status: 401, contentType: "application/json", bodyData: data, connection: connection)
            return
        }

        if method == "POST" && path == "/rpc" {
            handleRPC(body: body, connection: connection)
            return
        }

        if method == "POST" && path == "/mcp" {
            handleMCP(body: body, connection: connection)
            return
        }

        sendHTTPResponse(status: 404, body: "Not Found", connection: connection)
    }

    private func sendHTTPResponse(status: Int, contentType: String = "text/plain", body: String, connection: NWConnection) {
        let data = body.data(using: .utf8) ?? Data()
        sendHTTPResponse(status: status, contentType: contentType, bodyData: data, connection: connection)
    }

    private func sendHTTPResponse(status: Int, contentType: String = "text/plain", bodyData: Data, connection: NWConnection) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Status \(status)"
        }

        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var responseData = header.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    // MARK: - JSON-RPC 2.0 Dispatcher

    private func handleRPC(body: Data, connection: NWConnection) {
        Task { @MainActor in
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let methodName = json["method"] as? String else {
                self.sendRPCError(id: nil, code: -32700, message: "Parse error", connection: connection)
                return
            }

            let id = json["id"]
            let params = (json["params"] as? [String: Any]) ?? [:]

            do {
                let result = try await self.executeRPCMethod(name: methodName, params: params)
                self.sendRPCSuccess(id: id, result: result, connection: connection)
            } catch {
                self.sendRPCError(id: id, code: -32000, message: error.localizedDescription, connection: connection)
            }
        }
    }

    @MainActor
    private func executeRPCMethod(name: String, params: [String: Any]) async throws -> Any {
        let controller = AgentController.shared

        switch name {
        case "kylmora.status":
            return controller.status()

        case "kylmora.tabs.list":
            return ["tabs": controller.listTabs()]

        case "kylmora.spaces.list", "kylmora.profiles.list":
            return ["profiles": controller.listSpaces()]

        case "kylmora.tabs.open":
            guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
                throw AgentError.invalidTarget("Missing or invalid 'url'")
            }
            let profile = (params["profile"] as? String) ?? (params["space"] as? String)
            return try controller.openTab(url: url, profile: profile)

        case "kylmora.tabs.select":
            guard let idString = params["id"] as? String, let uuid = UUID(uuidString: idString) else {
                throw AgentError.invalidTarget("Missing or invalid 'id'")
            }
            return controller.selectTab(id: uuid)

        case "kylmora.tabs.close":
            guard let idString = params["id"] as? String, let uuid = UUID(uuidString: idString) else {
                throw AgentError.invalidTarget("Missing or invalid 'id'")
            }
            return controller.closeTab(id: uuid)

        case "kylmora.page.navigate":
            guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
                throw AgentError.invalidTarget("Missing or invalid 'url'")
            }
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.navigate(url: url, tabId: tabId)

        case "kylmora.page.snapshot":
            let scope = params["scope"] as? String
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.takeSnapshot(scope: scope, tabId: tabId)

        case "kylmora.page.click":
            let ref = params["ref"] as? String
            let x = params["x"] as? Double
            let y = params["y"] as? Double
            let label = params["label"] as? String
            let clickCount = (params["clickCount"] as? Int) ?? 1
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.click(ref: ref, x: x, y: y, label: label, clickCount: clickCount, tabId: tabId)

        case "kylmora.page.hover":
            let ref = params["ref"] as? String
            let x = params["x"] as? Double
            let y = params["y"] as? Double
            let label = params["label"] as? String
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.hover(ref: ref, x: x, y: y, label: label, tabId: tabId)

        case "kylmora.page.type":
            guard let text = params["text"] as? String else {
                throw AgentError.invalidTarget("Missing 'text'")
            }
            let ref = params["ref"] as? String
            let clear = (params["clear"] as? Bool) ?? false
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.type(text: text, ref: ref, clear: clear, tabId: tabId)

        case "kylmora.page.press":
            guard let key = params["key"] as? String else {
                throw AgentError.invalidTarget("Missing 'key'")
            }
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.press(key: key, tabId: tabId)

        case "kylmora.page.scroll":
            let dx = (params["deltaX"] as? Double) ?? 0
            let dy = (params["deltaY"] as? Double) ?? 400
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.scroll(deltaX: dx, deltaY: dy, tabId: tabId)

        case "kylmora.page.evaluate":
            guard let script = params["script"] as? String else {
                throw AgentError.invalidTarget("Missing 'script'")
            }
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            let res = try await controller.evaluate(script: script, tabId: tabId)
            return ["result": res ?? NSNull()]

        case "kylmora.page.screenshot":
            let tabId = (params["tabId"] as? String).flatMap(UUID.init(uuidString:))
            return try await controller.captureScreenshot(tabId: tabId)

        case "kylmora.agent.handoff":
            let reason = (params["reason"] as? String) ?? "Awaiting user interaction (e.g. login or captcha)"
            return controller.handOff(reason: reason)

        case "kylmora.agent.resume":
            return controller.resume()

        case "kylmora.agent.finish":
            return controller.finish()

        case "kylmora.agent.waitForControl":
            let timeout = (params["timeout"] as? Double) ?? 600
            return try await controller.waitForControl(timeout: timeout)

        // Older callers: control is now exclusive, as in ego lite.
        case "kylmora.agent.setMode":
            switch (params["mode"] as? String)?.lowercased() {
            case "ai": return controller.resume()
            case "user": return controller.handOff(reason: (params["reason"] as? String) ?? "Manual user control")
            default: throw AgentError.invalidTarget("Control is exclusive: use 'ai' (agent) or 'user'. Shared control was removed.")
            }

        case "kylmora.agent.getMode":
            return controller.status()

        default:
            throw AgentError.invalidTarget("Unknown method: \(name)")
        }
    }

    @MainActor
    private func sendRPCSuccess(id: Any?, result: Any, connection: NWConnection) {
        let resp: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ]
        let data = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data()
        sendHTTPResponse(status: 200, contentType: "application/json", bodyData: data, connection: connection)
    }

    @MainActor
    private func sendRPCError(id: Any?, code: Int, message: String, connection: NWConnection) {
        let resp: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data()
        sendHTTPResponse(status: 200, contentType: "application/json", bodyData: data, connection: connection)
    }

    // MARK: - Model Context Protocol (MCP) Support

    private func handleMCP(body: Data, connection: NWConnection) {
        Task { @MainActor in
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let method = json["method"] as? String else {
                self.sendRPCError(id: nil, code: -32700, message: "Parse error", connection: connection)
                return
            }

            let id = json["id"]
            let params = (json["params"] as? [String: Any]) ?? [:]

            switch method {
            case "initialize":
                let initResp: [String: Any] = [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "kylmora-browser", "version": "1.0.0"]
                ]
                self.sendRPCSuccess(id: id, result: initResp, connection: connection)

            case "tools/list":
                let tools = self.mcpToolCatalog()
                self.sendRPCSuccess(id: id, result: ["tools": tools], connection: connection)

            case "tools/call":
                guard let name = params["name"] as? String else {
                    self.sendRPCError(id: id, code: -32602, message: "Missing tool name", connection: connection)
                    return
                }
                let args = (params["arguments"] as? [String: Any]) ?? [:]
                do {
                    let toolOutput = try await self.executeMCPTool(name: name, args: args)
                    self.sendRPCSuccess(id: id, result: [
                        "content": [
                            ["type": "text", "text": toolOutput]
                        ]
                    ], connection: connection)
                } catch {
                    self.sendRPCSuccess(id: id, result: [
                        "isError": true,
                        "content": [
                            ["type": "text", "text": "Error: \(error.localizedDescription)"]
                        ]
                    ], connection: connection)
                }

            default:
                self.sendRPCError(id: id, code: -32601, message: "Method not found: \(method)", connection: connection)
            }
        }
    }

    private func mcpToolCatalog() -> [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema]
        }
        let ref: [String: Any] = ["type": "string", "description": "A snapshot ref such as '@3'."]
        let label: [String: Any] = ["type": "string", "description": "A 3-6 word description of the action, shown beside the agent's cursor."]
        return [
            tool("kylmora_profiles", "Lists the browser's profiles (spaces). Each has its own logins; pick one to work signed in as that profile."),
            tool("kylmora_open", "Opens a page in a new agent tab in a profile, signed in wherever that profile is. Defaults to the profile the user is in.",
                 ["url": ["type": "string"], "profile": ["type": "string", "description": "Profile (space) name, from kylmora_profiles."]], required: ["url"]),
            tool("kylmora_navigate", "Navigates the agent's tab to a URL and waits for it to load.",
                 ["url": ["type": "string"]], required: ["url"]),
            tool("kylmora_snapshot", "Lists what is on the agent's page: interactive elements with stable @refs, roles, names, values and states, plus headings for context. Refs stay valid until the page navigates.",
                 ["scope": ["type": "string", "enum": ["viewport", "full_page"], "description": "Defaults to 'viewport'."]]),
            tool("kylmora_click", "Clicks with real mouse input: the cursor travels to the element, it is scrolled into view, and it is checked to be visible, enabled and not covered.",
                 ["ref": ref, "x": ["type": "number"], "y": ["type": "number"], "label": label, "clickCount": ["type": "integer"]]),
            tool("kylmora_hover", "Moves the cursor onto an element with real pointer input, e.g. to open a hover menu.",
                 ["ref": ref, "x": ["type": "number"], "y": ["type": "number"], "label": label]),
            tool("kylmora_type", "Types text one key at a time at a person's pace. With ref, clicks the field first; with clear, empties it first.",
                 ["text": ["type": "string"], "ref": ref, "clear": ["type": "boolean"]], required: ["text"]),
            tool("kylmora_press", "Presses a key or chord, e.g. 'Enter', 'Tab', 'Escape', 'ArrowDown', 'Meta+a'.",
                 ["key": ["type": "string"]], required: ["key"]),
            tool("kylmora_scroll", "Scrolls with wheel input at the cursor, in small uneven steps.",
                 ["deltaY": ["type": "number", "description": "Pixels; positive scrolls down."], "deltaX": ["type": "number"]]),
            tool("kylmora_tabs", "Lists open tabs; the agent's tab is marked."),
            tool("kylmora_handoff", "Hands the page to the user for a captcha, login, 2FA or anything identity-related. Stop after calling this and tell the user what to do.",
                 ["reason": ["type": "string", "description": "What the user needs to do."]], required: ["reason"]),
            tool("kylmora_wait_for_control", "Waits until the user gives control back to the agent.",
                 ["timeout": ["type": "number", "description": "Seconds; defaults to 600."]]),
            tool("kylmora_resume", "Takes control back after the user confirmed they are done."),
            tool("kylmora_finish", "Ends the task: removes the agent's cursor and frees the page."),
            tool("kylmora_status", "Reports who controls the page (agent, user or idle) and the agent's tab."),
        ]
    }

    @MainActor
    private func executeMCPTool(name: String, args: [String: Any]) async throws -> String {
        let controller = AgentController.shared
        let ref = args["ref"] as? String
        let x = args["x"] as? Double
        let y = args["y"] as? Double
        let label = args["label"] as? String

        switch name {
        case "kylmora_open":
            guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
                throw AgentError.invalidTarget("Invalid URL")
            }
            let result = try controller.openTab(url: url, profile: args["profile"] as? String)
            return "Opened \(urlString) in profile \(result["profile"] ?? "") (tab \(result["id"] ?? ""))"

        case "kylmora_profiles":
            return controller.listSpaces().map { profile in
                let active = profile["active"] as? Bool == true ? " [CURRENT]" : ""
                return "\(profile["name"] ?? "") — \(profile["identity"] ?? ""), \(profile["tabCount"] ?? 0) tabs\(active)"
            }.joined(separator: "\n")

        case "kylmora_navigate":
            guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
                throw AgentError.invalidTarget("Invalid URL")
            }
            let result = try await controller.navigate(url: url)
            return "Loaded \(result["url"] ?? urlString) — \(result["title"] ?? "")"

        case "kylmora_snapshot":
            let result = try await controller.takeSnapshot(scope: args["scope"] as? String)
            return (result["markdown"] as? String) ?? "(Empty snapshot)"

        case "kylmora_click":
            let result = try await controller.click(ref: ref, x: x, y: y, label: label, clickCount: (args["clickCount"] as? Int) ?? 1)
            return "Clicked \(ref ?? "") at (\(result["x"] ?? 0), \(result["y"] ?? 0))"

        case "kylmora_hover":
            let result = try await controller.hover(ref: ref, x: x, y: y, label: label)
            return "Pointer on \(ref ?? "") at (\(result["x"] ?? 0), \(result["y"] ?? 0))"

        case "kylmora_type":
            guard let text = args["text"] as? String else { throw AgentError.invalidTarget("Missing text") }
            _ = try await controller.type(text: text, ref: ref, clear: (args["clear"] as? Bool) ?? false)
            return "Typed \(text.count) characters into \(ref ?? "the focused field")"

        case "kylmora_press":
            guard let key = args["key"] as? String else { throw AgentError.invalidTarget("Missing key") }
            _ = try await controller.press(key: key)
            return "Pressed \(key)"

        case "kylmora_scroll":
            let dy = (args["deltaY"] as? Double) ?? 400
            let dx = (args["deltaX"] as? Double) ?? 0
            _ = try await controller.scroll(deltaX: dx, deltaY: dy)
            return "Scrolled \(Int(dy))px"

        case "kylmora_tabs":
            let formatted = controller.listTabs().map { tab in
                let marker = tab["agent"] as? Bool == true ? " [AGENT]" : (tab["active"] as? Bool == true ? " [USER]" : "")
                return "[\(tab["id"] ?? "")] [profile: \(tab["space"] ?? "")] \(tab["title"] ?? "") (\(tab["url"] ?? ""))\(marker)"
            }.joined(separator: "\n")
            return formatted.isEmpty ? "No open tabs" : formatted

        case "kylmora_handoff":
            let reason = (args["reason"] as? String) ?? "Captcha or login required"
            _ = controller.handOff(reason: reason)
            return "Handed the page to the user: \(reason). Stop here and tell them what to do."

        case "kylmora_wait_for_control":
            _ = try await controller.waitForControl(timeout: (args["timeout"] as? Double) ?? 600)
            return "The agent has control again."

        case "kylmora_resume":
            _ = controller.resume()
            return "Resumed control of the page"

        case "kylmora_finish":
            _ = controller.finish()
            return "Task finished"

        case "kylmora_status":
            let status = controller.status()
            return "control: \(status["control"] ?? "") \(status["detail"] ?? "")\nagent tab: \(status["agentTab"] ?? "")"

        default:
            throw AgentError.invalidTarget("Unknown tool: \(name)")
        }
    }
}
