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

        // Try default port 4999 on loopback first; if unavailable, use an ephemeral loopback port
        let targetPort: NWEndpoint.Port = NWEndpoint.Port(rawValue: 4999) ?? .any
        let parameters = Self.loopbackParameters(port: targetPort)

        do {
            let listener = try NWListener(using: parameters)
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
                    // Retry on any ephemeral loopback port if default was busy
                    if targetPort != .any {
                        self.retryWithEphemeralPort()
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

    private static func loopbackParameters(port: NWEndpoint.Port) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        return parameters
    }

    private func retryWithEphemeralPort() {
        listener?.cancel()
        listener = nil
        do {
            let fallbackListener = try NWListener(using: Self.loopbackParameters(port: .any))
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

        let fm = FileManager.default
        // Write to App Support with owner-only permissions
        let appSupportFile = AppPaths.supportDirectory.appending(path: "agent-runtime.json")
        try? data.write(to: appSupportFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: appSupportFile.path)

        // Write to ~/.kylmora/agent-runtime.json with owner-only permissions
        let userHome = fm.homeDirectoryForCurrentUser
        let dotKylmora = userHome.appending(path: ".kylmora", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dotKylmora, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dotKylmora.path)
        let dotRuntimeFile = dotKylmora.appending(path: "agent-runtime.json")
        try? data.write(to: dotRuntimeFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotRuntimeFile.path)
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

    private static let maxRequestBytes = 4 * 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private func readHTTPRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var data = accumulated
            if let content {
                data.append(content)
            }

            if data.count > Self.maxRequestBytes {
                self.sendHTTPResponse(status: 413, body: "Payload Too Large", connection: connection)
                return
            }

            if let headerEndRange = data.range(of: Self.headerTerminator) {
                // Headers complete; decode header bytes only so split UTF-8 in the body never stalls parsing
                let headerBytes = data[..<headerEndRange.lowerBound]
                let headerText = String(data: headerBytes, encoding: .utf8)
                    ?? String(data: headerBytes, encoding: .isoLatin1)
                    ?? ""
                let bodyStartIndex = headerEndRange.upperBound
                let bodyData = data[bodyStartIndex..<data.endIndex]

                var contentLength = 0
                var expectsContinue = false
                for line in headerText.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("expect:") && line.lowercased().contains("100-continue") {
                        expectsContinue = true
                    }
                    if line.lowercased().hasPrefix("content-length:") {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count > 1, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                            contentLength = max(0, len)
                        }
                    }
                }

                if contentLength > Self.maxRequestBytes {
                    self.sendHTTPResponse(status: 413, body: "Payload Too Large", connection: connection)
                    return
                }

                if bodyData.count >= contentLength {
                    let exactBody = contentLength > 0 ? Data(bodyData.prefix(contentLength)) : Data()
                    self.dispatchHTTPRequest(headerText: headerText, body: exactBody, connection: connection)
                    return
                } else if expectsContinue && bodyData.isEmpty {
                    let cont = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
                    connection.send(content: cont, completion: .contentProcessed { _ in })
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
        case 413: statusText = "Payload Too Large"
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
            } catch let agentErr as AgentError {
                self.sendRPCError(id: id, code: -32000, message: agentErr.localizedDescription, errorCode: agentErr.errorCode, connection: connection)
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
            guard let uuid = controller.resolveTabID((params["id"] as? String) ?? (params["page"] as? String)) else {
                throw AgentError.invalidTarget("Missing or invalid 'id' or 'page'")
            }
            return try controller.selectTab(id: uuid)

        case "kylmora.tabs.close":
            guard let uuid = controller.resolveTabID((params["id"] as? String) ?? (params["page"] as? String)) else {
                throw AgentError.invalidTarget("Missing or invalid 'id' or 'page'")
            }
            return try controller.closeTab(id: uuid)

        case "kylmora.page.navigate":
            guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
                throw AgentError.invalidTarget("Missing or invalid 'url'")
            }
            let timeout = (params["timeout"] as? Double) ?? 30
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.navigate(url: url, timeout: timeout, tabId: tabId)

        case "kylmora.page.snapshot":
            let scope = params["scope"] as? String
            let root = params["root"] as? String
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.takeSnapshot(scope: scope, root: root, tabId: tabId)

        case "kylmora.page.info":
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try controller.pageInfo(tabId: tabId)

        case "kylmora.page.click":
            let ref = (params["ref"] as? String) ?? (params["selector"] as? String)
            let x = params["x"] as? Double
            let y = params["y"] as? Double
            let label = params["label"] as? String
            let clickCount = (params["clickCount"] as? Int) ?? 1
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.click(ref: ref, x: x, y: y, label: label, clickCount: clickCount, tabId: tabId)

        case "kylmora.page.hover":
            let ref = (params["ref"] as? String) ?? (params["selector"] as? String)
            let x = params["x"] as? Double
            let y = params["y"] as? Double
            let label = params["label"] as? String
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.hover(ref: ref, x: x, y: y, label: label, tabId: tabId)

        case "kylmora.page.type":
            guard let text = params["text"] as? String else {
                throw AgentError.invalidTarget("Missing 'text'")
            }
            let ref = (params["ref"] as? String) ?? (params["selector"] as? String)
            let clear = (params["clear"] as? Bool) ?? false
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.type(text: text, ref: ref, clear: clear, tabId: tabId)

        case "kylmora.page.press":
            guard let key = params["key"] as? String else {
                throw AgentError.invalidTarget("Missing 'key'")
            }
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.press(key: key, tabId: tabId)

        case "kylmora.page.scroll":
            let dx = (params["deltaX"] as? Double) ?? 0
            let dy = (params["deltaY"] as? Double) ?? 400
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.scroll(deltaX: dx, deltaY: dy, tabId: tabId)

        case "kylmora.page.evaluate":
            guard let script = params["script"] as? String else {
                throw AgentError.invalidTarget("Missing 'script'")
            }
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            let res = try await controller.evaluate(script: script, tabId: tabId)
            return ["result": res ?? NSNull()]

        case "kylmora.page.dblclick":
            let ref = (params["ref"] as? String) ?? (params["selector"] as? String)
            let x = params["x"] as? Double
            let y = params["y"] as? Double
            let label = params["label"] as? String
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.doubleClick(ref: ref, x: x, y: y, label: label, tabId: tabId)

        case "kylmora.page.drag":
            guard let from = params["from"] as? String, let to = params["to"] as? String else {
                throw AgentError.invalidTarget("Missing 'from' or 'to'")
            }
            let label = params["label"] as? String
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.dragAndDrop(from: from, to: to, label: label, tabId: tabId)

        case "kylmora.page.paste":
            guard let text = params["text"] as? String else {
                throw AgentError.invalidTarget("Missing 'text'")
            }
            let html = params["html"] as? String
            let ref = (params["ref"] as? String) ?? (params["selector"] as? String)
            let clear = (params["clear"] as? Bool) ?? false
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.paste(text: text, html: html, ref: ref, clear: clear, tabId: tabId)

        case "kylmora.page.selectOption":
            guard let ref = (params["ref"] as? String) ?? (params["selector"] as? String) else {
                throw AgentError.invalidTarget("Missing 'ref' or 'selector'")
            }
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.selectOption(
                ref: ref,
                value: params["value"] as? String,
                label: params["label"] as? String,
                index: params["index"] as? Int,
                tabId: tabId
            )

        case "kylmora.page.waitForSelector":
            guard let selector = params["selector"] as? String else {
                throw AgentError.invalidTarget("Missing 'selector'")
            }
            let state = (params["state"] as? String) ?? "visible"
            let timeout = (params["timeout"] as? Double) ?? 10
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.waitForSelector(selector: selector, state: state, timeout: timeout, tabId: tabId)

        case "kylmora.page.waitForFunction":
            guard let expression = params["expression"] as? String else {
                throw AgentError.invalidTarget("Missing 'expression'")
            }
            let timeout = (params["timeout"] as? Double) ?? 10
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.waitForFunction(expression: expression, timeout: timeout, tabId: tabId)

        case "kylmora.page.text":
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            let limit = (params["limit"] as? Int) ?? 120_000
            let text = try await controller.pageText(tabId: tabId, limit: limit)
            return ["text": text]

        case "kylmora.page.back":
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.goBack(tabId: tabId)

        case "kylmora.page.forward":
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.goForward(tabId: tabId)

        case "kylmora.page.reload":
            let timeout = (params["timeout"] as? Double) ?? 30
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            return try await controller.reload(timeout: timeout, tabId: tabId)

        case "kylmora.page.screenshot":
            let tabId = controller.resolveTabID(params["tabId"] as? String)
            let path = params["path"] as? String
            let includeBase64 = (params["base64"] as? Bool) ?? false
            return try await controller.captureScreenshot(path: path, includeBase64: includeBase64, tabId: tabId)

        case "kylmora.agent.handoff":
            let reason = (params["reason"] as? String) ?? "Awaiting user interaction (e.g. login or captcha)"
            return controller.handOff(reason: reason)

        case "kylmora.agent.resume":
            return controller.resume()

        case "kylmora.agent.finish":
            let keep = params["keep"] as? [String]
            return controller.finish(keep: keep)

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

        case "kylmora.page.focus":
            guard let ref = (params["ref"] as? String) ?? (params["selector"] as? String) else {
                throw AgentError.invalidTarget("Missing 'ref' or 'selector'")
            }
            return try await controller.focus(ref: ref, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.fill":
            guard let ref = (params["ref"] as? String) ?? (params["selector"] as? String),
                  let value = (params["value"] as? String) ?? (params["text"] as? String) else {
                throw AgentError.invalidTarget("Missing 'ref' and 'value'")
            }
            return try await controller.fill(ref: ref, value: value, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.insertText":
            guard let text = params["text"] as? String else { throw AgentError.invalidTarget("Missing 'text'") }
            return try await controller.insertText(text: text, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.mouse.down":
            return try await controller.mouseDown(button: (params["button"] as? String) ?? "left", tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.mouse.up":
            return try await controller.mouseUp(button: (params["button"] as? String) ?? "left", tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.keyboard.down":
            guard let key = params["key"] as? String else { throw AgentError.invalidTarget("Missing 'key'") }
            return try await controller.keyDown(key: key, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.keyboard.up":
            guard let key = params["key"] as? String else { throw AgentError.invalidTarget("Missing 'key'") }
            return try await controller.keyUp(key: key, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.waitForURL":
            guard let pattern = (params["pattern"] as? String) ?? (params["url"] as? String) else {
                throw AgentError.invalidTarget("Missing 'pattern' or 'url'")
            }
            let timeout = (params["timeout"] as? Double) ?? 10
            return try await controller.waitForURL(pattern: pattern, timeout: timeout, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.waitForLoadState":
            let state = (params["state"] as? String) ?? "load"
            let timeout = (params["timeout"] as? Double) ?? 15
            return try await controller.waitForLoadState(state: state, timeout: timeout, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.waitForTimeout":
            let ms = (params["ms"] as? Int) ?? Int((params["ms"] as? Double) ?? 500)
            return try await controller.waitForTimeout(ms: ms)

        case "kylmora.page.acceptDialog":
            return try controller.acceptDialog(promptText: params["promptText"] as? String, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.dismissDialog":
            return try controller.dismissDialog(tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.setInputFiles":
            guard let ref = (params["ref"] as? String) ?? (params["selector"] as? String),
                  let files = params["files"] as? [String] else {
                throw AgentError.invalidTarget("Missing 'ref' and 'files'")
            }
            return try await controller.setInputFiles(ref: ref, files: files, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.waitForFileChooser":
            let timeout = (params["timeout"] as? Double) ?? 10
            return try await controller.waitForFileChooser(timeout: timeout, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.setChooserFiles":
            guard let cid = params["chooserId"] as? String, let files = params["files"] as? [String] else {
                throw AgentError.invalidTarget("Missing 'chooserId' and 'files'")
            }
            return try controller.setChooserFiles(chooserId: cid, files: files)

        case "kylmora.page.cancelFileChooser":
            guard let cid = params["chooserId"] as? String else { throw AgentError.invalidTarget("Missing 'chooserId'") }
            return try controller.cancelFileChooser(chooserId: cid)

        case "kylmora.page.waitForPopup":
            let timeout = (params["timeout"] as? Double) ?? 10
            return try await controller.waitForPopup(timeout: timeout, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.waitForDownload":
            let timeout = (params["timeout"] as? Double) ?? 30
            return try await controller.waitForDownload(timeout: timeout, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.download.saveAs":
            guard let dlId = params["downloadId"] as? String, let path = params["path"] as? String else {
                throw AgentError.invalidTarget("Missing 'downloadId' and 'path'")
            }
            return try await controller.saveDownload(downloadId: dlId, path: path)

        case "kylmora.download.cancel":
            guard let dlId = params["downloadId"] as? String else { throw AgentError.invalidTarget("Missing 'downloadId'") }
            return try controller.cancelDownload(downloadId: dlId)

        case "kylmora.page.fetch":
            guard let url = params["url"] as? String else { throw AgentError.invalidTarget("Missing 'url'") }
            let method = (params["method"] as? String) ?? "GET"
            let headers = (params["headers"] as? [String: String]) ?? [:]
            let body = params["body"] as? String
            let saveAs = params["saveAs"] as? String
            let timeout = (params["timeout"] as? Double) ?? 15
            return try await controller.pageFetch(url: url, method: method, headers: headers, body: body, saveAs: saveAs, timeout: timeout, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.page.pdf":
            guard let path = params["path"] as? String else { throw AgentError.invalidTarget("Missing 'path'") }
            return try await controller.exportPDF(path: path, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.cookies.list":
            return try await controller.listCookies(url: params["url"] as? String, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.cookies.set":
            guard let cname = params["name"] as? String,
                  let cval = params["value"] as? String,
                  let cdom = params["domain"] as? String else {
                throw AgentError.invalidTarget("Missing 'name', 'value', or 'domain'")
            }
            return try await controller.setCookie(name: cname, value: cval, domain: cdom, path: (params["path"] as? String) ?? "/", secure: (params["secure"] as? Bool) ?? true, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.cookies.delete":
            guard let cname = params["name"] as? String else { throw AgentError.invalidTarget("Missing 'name'") }
            return try await controller.deleteCookie(name: cname, domain: params["domain"] as? String, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.storage.clear":
            guard let origin = params["origin"] as? String else { throw AgentError.invalidTarget("Missing 'origin'") }
            let types = (params["types"] as? [String]) ?? ["cookies", "localStorage", "cache", "indexedDB"]
            return try await controller.clearStorage(origin: origin, types: types, tabId: controller.resolveTabID(params["tabId"] as? String))

        case "kylmora.batch":
            guard let steps = params["steps"] as? [[String: Any]] else {
                throw AgentError.invalidTarget("Missing 'steps' array")
            }
            let stopOnDialog = (params["stopOnDialog"] as? Bool) ?? true
            var results: [Any] = []
            var stoppedReason: String? = nil
            var errorObj: [String: Any]? = nil
            for step in steps {
                guard let m = step["method"] as? String else {
                    stoppedReason = "error"
                    errorObj = ["code": "INVALID_TARGET", "message": "Batch step missing 'method'"]
                    break
                }
                let p = (step["params"] as? [String: Any]) ?? [:]
                do {
                    let res = try await executeRPCMethod(name: m, params: p)
                    results.append(Self.sanitizeJSONValue(res))
                    if stopOnDialog, let dict = res as? [String: Any], dict["dialog"] != nil {
                        stoppedReason = "dialog"
                        break
                    }
                } catch let agentErr as AgentError {
                    stoppedReason = agentErr.errorCode == "USER_IN_CONTROL" ? "user_in_control" : "error"
                    errorObj = ["code": agentErr.errorCode, "message": agentErr.localizedDescription]
                    break
                } catch {
                    stoppedReason = "error"
                    errorObj = ["code": "ERROR", "message": error.localizedDescription]
                    break
                }
            }
            var out: [String: Any] = ["completed": results.count, "results": results]
            if let stoppedReason { out["stoppedReason"] = stoppedReason }
            if let errorObj { out["error"] = errorObj }
            if stoppedReason == nil, let snapScope = params["finalSnapshot"] as? String {
                if let snap = try? await controller.takeSnapshot(scope: snapScope, tabId: controller.resolveTabID(params["tabId"] as? String)),
                   let md = snap["markdown"] as? String {
                    out["snapshot"] = md
                }
            }
            return out

        default:
            throw AgentError.invalidTarget("Unknown method: \(name)")
        }
    }

    /// Converts arbitrary values (e.g. WebKit JS results containing Date, NaN, Infinity, URL)
    /// into JSONSerialization-safe values so serialization never raises NSInvalidArgumentException.
    static func sanitizeJSONValue(_ value: Any) -> Any {
        switch value {
        case is NSNull, is String, is Bool:
            return value
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            let d = number.doubleValue
            return d.isFinite ? number : NSNull()
        case let d as Double:
            return d.isFinite ? d : NSNull()
        case let f as Float:
            return f.isFinite ? f : NSNull()
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.absoluteString
        case let array as [Any]:
            return array.map { sanitizeJSONValue($0) }
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeJSONValue($0) }
        default:
            return String(describing: value)
        }
    }

    @MainActor
    private func sendRPCSuccess(id: Any?, result: Any, connection: NWConnection) {
        let resp: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Self.sanitizeJSONValue(id ?? NSNull()),
            "result": Self.sanitizeJSONValue(result)
        ]
        let data: Data
        if JSONSerialization.isValidJSONObject(resp),
           let encoded = try? JSONSerialization.data(withJSONObject: resp) {
            data = encoded
        } else {
            data = Data("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Response not JSON-serializable\"}}".utf8)
        }
        sendHTTPResponse(status: 200, contentType: "application/json", bodyData: data, connection: connection)
    }

    @MainActor
    private func sendRPCError(id: Any?, code: Int, message: String, errorCode: String? = nil, connection: NWConnection) {
        var errObj: [String: Any] = ["code": code, "message": message]
        if let errorCode { errObj["data"] = ["code": errorCode] }
        let resp: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": errObj
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
        let ref: [String: Any] = ["type": "string", "description": "Snapshot ref ('@3') or selector (CSS, 'text=...', 'loc=role:button[name=\'Save\']', 'loc=href:...', 'xpath=...', '>> nth=N')."]
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
            tool("kylmora_dblclick", "Double-clicks an element or coordinates with real mouse input.",
                 ["ref": ref, "x": ["type": "number"], "y": ["type": "number"], "label": label]),
            tool("kylmora_drag", "Drags from one element to another with real mouseDown, curve drag, and mouseUp.",
                 ["from": ref, "to": ref, "label": label], required: ["from", "to"]),
            tool("kylmora_paste", "Pastes text via native Cmd+V (preserving the user's clipboard). Faster for long text or rich editors.",
                 ["text": ["type": "string"], "ref": ref, "clear": ["type": "boolean"]], required: ["text"]),
            tool("kylmora_select_option", "Selects an option in a <select> dropdown by value, visible label, or 0-based index.",
                 ["ref": ref, "value": ["type": "string"], "label": ["type": "string"], "index": ["type": "integer"]], required: ["ref"]),
            tool("kylmora_wait_for_selector", "Waits until a selector is visible, hidden, or attached.",
                 ["selector": ref, "state": ["type": "string", "enum": ["visible", "hidden", "attached"]], "timeout": ["type": "number"]], required: ["selector"]),
            tool("kylmora_wait_for_function", "Waits until a JavaScript expression evaluates truthy.",
                 ["expression": ["type": "string"], "timeout": ["type": "number"]], required: ["expression"]),
            tool("kylmora_page_text", "Returns the page's title, URL, and readable body text."),
            tool("kylmora_screenshot", "Captures a PNG screenshot of the visible page and returns its absolute file path.",
                 ["path": ["type": "string", "description": "Optional absolute file path for the PNG."]]),
            tool("kylmora_evaluate", "Runs read-only JavaScript in the isolated agent world and returns JSON-safe output.",
                 ["script": ["type": "string"]], required: ["script"]),
            tool("kylmora_back", "Navigates back in the agent tab's history."),
            tool("kylmora_forward", "Navigates forward in the agent tab's history."),
            tool("kylmora_reload", "Reloads the agent tab."),
            tool("kylmora_select_tab", "Switches the agent's target tab by page label (e.g. 'p1') or UUID.",
                 ["tabId": ["type": "string"]], required: ["tabId"]),
            tool("kylmora_close_tab", "Closes a tab by page label or UUID.",
                 ["tabId": ["type": "string"]], required: ["tabId"]),
            tool("kylmora_page_info", "Returns metadata (url, title, page label, canGoBack, canGoForward, openedBy, active dialog) for a tab.",
                 ["tabId": ["type": "string"]]),
            tool("kylmora_focus", "Focuses an element by @ref or selector without clicking it.",
                 ["ref": ref, "tabId": ["type": "string"]], required: ["ref"]),
            tool("kylmora_fill", "Atomically focuses, clears, and fills an input/textarea/contenteditable with text (fast, Unicode-safe).",
                 ["ref": ref, "value": ["type": "string"], "tabId": ["type": "string"]], required: ["ref", "value"]),
            tool("kylmora_insert_text", "Inserts text directly into the focused field without clipboard side effects.",
                 ["text": ["type": "string"], "tabId": ["type": "string"]], required: ["text"]),
            tool("kylmora_wait_for_url", "Waits until the tab URL matches a substring, glob (*), or /regex/.",
                 ["pattern": ["type": "string"], "timeout": ["type": "number"], "tabId": ["type": "string"]], required: ["pattern"]),
            tool("kylmora_wait_for_load_state", "Waits for domcontentloaded, load, or networkidle.",
                 ["state": ["type": "string", "enum": ["domcontentloaded", "load", "networkidle"]], "timeout": ["type": "number"], "tabId": ["type": "string"]]),
            tool("kylmora_accept_dialog", "Accepts an active JS alert/confirm/prompt dialog (with optional promptText).",
                 ["promptText": ["type": "string"], "tabId": ["type": "string"]]),
            tool("kylmora_dismiss_dialog", "Dismisses an active JS alert/confirm/prompt dialog.",
                 ["tabId": ["type": "string"]]),
            tool("kylmora_set_input_files", "Uploads one or more absolute file paths to a file input without opening a native sheet.",
                 ["ref": ref, "files": ["type": "array", "items": ["type": "string"]], "tabId": ["type": "string"]], required: ["ref", "files"]),
            tool("kylmora_wait_for_popup", "Waits for a target=_blank / window.open popup tab and returns its page label.",
                 ["timeout": ["type": "number"], "tabId": ["type": "string"]]),
            tool("kylmora_wait_for_download", "Waits for a browser download on the tab and returns its downloadId.",
                 ["timeout": ["type": "number"], "tabId": ["type": "string"]]),
            tool("kylmora_download_save_as", "Saves a completed download to an absolute path.",
                 ["downloadId": ["type": "string"], "path": ["type": "string"]], required: ["downloadId", "path"]),
            tool("kylmora_fetch", "Runs window.fetch() inside the page with its cookies/session; optional saveAs writes binary response to disk.",
                 ["url": ["type": "string"], "method": ["type": "string"], "body": ["type": "string"], "saveAs": ["type": "string"], "tabId": ["type": "string"]], required: ["url"]),
            tool("kylmora_pdf", "Exports the current page as a PDF to an absolute file path.",
                 ["path": ["type": "string"], "tabId": ["type": "string"]], required: ["path"]),
            tool("kylmora_cookies", "Lists cookies for the current profile (optionally filtered by URL).",
                 ["url": ["type": "string"], "tabId": ["type": "string"]]),
            tool("kylmora_batch", "Executes multiple JSON-RPC steps in one round-trip with optional finalSnapshot.",
                 ["steps": ["type": "array", "items": ["type": "object"]], "finalSnapshot": ["type": "string", "enum": ["viewport", "full_page"]]], required: ["steps"]),
            tool("kylmora_status", "Reports who controls the page (agent, user or idle) and the agent's tab."),
        ]
    }

    @MainActor
    private func executeMCPTool(name: String, args: [String: Any]) async throws -> String {
        let controller = AgentController.shared
        let ref = (args["ref"] as? String) ?? (args["selector"] as? String)
        let x = args["x"] as? Double
        let y = args["y"] as? Double
        let label = args["label"] as? String
        let tabId = controller.resolveTabID((args["tabId"] as? String) ?? (args["page"] as? String))

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
            let result = try await controller.navigate(url: url, tabId: tabId)
            return "Loaded \(result["url"] ?? urlString) — \(result["title"] ?? "")"

        case "kylmora_snapshot":
            let result = try await controller.takeSnapshot(scope: args["scope"] as? String, root: args["root"] as? String, tabId: tabId)
            return (result["markdown"] as? String) ?? "(Empty snapshot)"

        case "kylmora_click":
            let result = try await controller.click(ref: ref, x: x, y: y, label: label, clickCount: (args["clickCount"] as? Int) ?? 1, tabId: tabId)
            return "Clicked \(ref ?? "") at (\(result["x"] ?? 0), \(result["y"] ?? 0))"

        case "kylmora_hover":
            let result = try await controller.hover(ref: ref, x: x, y: y, label: label, tabId: tabId)
            return "Pointer on \(ref ?? "") at (\(result["x"] ?? 0), \(result["y"] ?? 0))"

        case "kylmora_type":
            guard let text = args["text"] as? String else { throw AgentError.invalidTarget("Missing text") }
            _ = try await controller.type(text: text, ref: ref, clear: (args["clear"] as? Bool) ?? false, tabId: tabId)
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

        case "kylmora_dblclick":
            let result = try await controller.doubleClick(ref: ref, x: x, y: y, label: label)
            return "Double-clicked \(ref ?? "") at (\(result["x"] ?? 0), \(result["y"] ?? 0))"

        case "kylmora_drag":
            guard let from = args["from"] as? String, let to = args["to"] as? String else {
                throw AgentError.invalidTarget("Missing from or to")
            }
            _ = try await controller.dragAndDrop(from: from, to: to, label: label)
            return "Dragged \(from) to \(to)"

        case "kylmora_paste":
            guard let text = args["text"] as? String else { throw AgentError.invalidTarget("Missing text") }
            _ = try await controller.paste(text: text, ref: ref, clear: (args["clear"] as? Bool) ?? false)
            return "Pasted \(text.count) characters"

        case "kylmora_select_option":
            guard let target = ref else { throw AgentError.invalidTarget("Missing ref") }
            let result = try await controller.selectOption(ref: target, value: args["value"] as? String, label: args["label"] as? String, index: args["index"] as? Int)
            return "Selected \(result["label"] ?? result["value"] ?? "")"

        case "kylmora_wait_for_selector":
            guard let selector = args["selector"] as? String else { throw AgentError.invalidTarget("Missing selector") }
            _ = try await controller.waitForSelector(selector: selector, state: (args["state"] as? String) ?? "visible", timeout: (args["timeout"] as? Double) ?? 10)
            return "Matched \(selector)"

        case "kylmora_wait_for_function":
            guard let expr = args["expression"] as? String else { throw AgentError.invalidTarget("Missing expression") }
            _ = try await controller.waitForFunction(expression: expr, timeout: (args["timeout"] as? Double) ?? 10)
            return "Condition satisfied"

        case "kylmora_page_text":
            return try await controller.pageText()

        case "kylmora_screenshot":
            let result = try await controller.captureScreenshot(path: args["path"] as? String, includeBase64: false)
            return "Saved screenshot to \(result["path"] ?? "")"

        case "kylmora_evaluate":
            guard let script = args["script"] as? String else { throw AgentError.invalidTarget("Missing script") }
            let res = try await controller.evaluate(script: script)
            let safe = Self.sanitizeJSONValue(res ?? NSNull())
            if JSONSerialization.isValidJSONObject(["v": safe]),
               let data = try? JSONSerialization.data(withJSONObject: safe, options: .fragmentsAllowed),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return String(describing: safe)

        case "kylmora_back":
            let result = try await controller.goBack()
            return "Back to \(result["url"] ?? "")"

        case "kylmora_forward":
            let result = try await controller.goForward()
            return "Forward to \(result["url"] ?? "")"

        case "kylmora_reload":
            let result = try await controller.reload()
            return "Reloaded \(result["url"] ?? "")"

        case "kylmora_select_tab":
            guard let id = tabId else { throw AgentError.invalidTarget("Missing or invalid 'tabId'") }
            let res = try controller.selectTab(id: id)
            return "Selected tab \(res["page"] ?? "") (\(res["id"] ?? ""))"

        case "kylmora_close_tab":
            guard let id = tabId else { throw AgentError.invalidTarget("Missing or invalid 'tabId'") }
            _ = try controller.closeTab(id: id)
            return "Closed tab \(id.uuidString)"

        case "kylmora_page_info":
            let info = try controller.pageInfo(tabId: tabId)
            let data = try JSONSerialization.data(withJSONObject: Self.sanitizeJSONValue(info), options: [.prettyPrinted])
            return String(data: data, encoding: .utf8) ?? "{}"

        case "kylmora_focus":
            guard let ref else { throw AgentError.invalidTarget("Missing 'ref'") }
            _ = try await controller.focus(ref: ref, tabId: tabId)
            return "Focused \(ref)"

        case "kylmora_fill":
            guard let ref, let val = (args["value"] as? String) ?? (args["text"] as? String) else {
                throw AgentError.invalidTarget("Missing 'ref' and 'value'")
            }
            _ = try await controller.fill(ref: ref, value: val, tabId: tabId)
            return "Filled \(ref) with \(val.count) characters"

        case "kylmora_insert_text":
            guard let text = args["text"] as? String else { throw AgentError.invalidTarget("Missing 'text'") }
            _ = try await controller.insertText(text: text, tabId: tabId)
            return "Inserted \(text.count) characters"

        case "kylmora_wait_for_url":
            guard let pat = (args["pattern"] as? String) ?? (args["url"] as? String) else { throw AgentError.invalidTarget("Missing 'pattern'") }
            let res = try await controller.waitForURL(pattern: pat, timeout: (args["timeout"] as? Double) ?? 10, tabId: tabId)
            return "URL matched: \(res["url"] ?? "")"

        case "kylmora_wait_for_load_state":
            let st = (args["state"] as? String) ?? "load"
            let res = try await controller.waitForLoadState(state: st, timeout: (args["timeout"] as? Double) ?? 15, tabId: tabId)
            return "Load state \(st) reached on \(res["url"] ?? "")"

        case "kylmora_accept_dialog":
            let res = try controller.acceptDialog(promptText: args["promptText"] as? String, tabId: tabId)
            return "Accepted \(res["type"] ?? "dialog"): \(res["message"] ?? "")"

        case "kylmora_dismiss_dialog":
            let res = try controller.dismissDialog(tabId: tabId)
            return "Dismissed \(res["type"] ?? "dialog"): \(res["message"] ?? "")"

        case "kylmora_set_input_files":
            guard let ref, let files = args["files"] as? [String] else { throw AgentError.invalidTarget("Missing 'ref' and 'files'") }
            let res = try await controller.setInputFiles(ref: ref, files: files, tabId: tabId)
            return "Uploaded \((res["files"] as? [String])?.count ?? 0) file(s) to \(ref)"

        case "kylmora_wait_for_popup":
            let res = try await controller.waitForPopup(timeout: (args["timeout"] as? Double) ?? 10, tabId: tabId)
            return "Popup opened: \(res["page"] ?? "") (\(res["url"] ?? ""))"

        case "kylmora_wait_for_download":
            let res = try await controller.waitForDownload(timeout: (args["timeout"] as? Double) ?? 30, tabId: tabId)
            return "Download \(res["downloadId"] ?? ""): \(res["suggestedFilename"] ?? "") (\(res["state"] ?? ""))"

        case "kylmora_download_save_as":
            guard let dlId = args["downloadId"] as? String, let path = args["path"] as? String else {
                throw AgentError.invalidTarget("Missing 'downloadId' and 'path'")
            }
            let res = try await controller.saveDownload(downloadId: dlId, path: path)
            return "Saved download to \(res["path"] ?? path) (\(res["bytes"] ?? 0) bytes)"

        case "kylmora_fetch":
            guard let url = args["url"] as? String else { throw AgentError.invalidTarget("Missing 'url'") }
            let res = try await controller.pageFetch(url: url, method: (args["method"] as? String) ?? "GET", body: args["body"] as? String, saveAs: args["saveAs"] as? String, tabId: tabId)
            let data = try JSONSerialization.data(withJSONObject: Self.sanitizeJSONValue(res), options: [.prettyPrinted])
            return String(data: data, encoding: .utf8) ?? "{}"

        case "kylmora_pdf":
            guard let path = args["path"] as? String else { throw AgentError.invalidTarget("Missing 'path'") }
            let res = try await controller.exportPDF(path: path, tabId: tabId)
            return "Saved PDF to \(res["path"] ?? path) (\(res["bytes"] ?? 0) bytes)"

        case "kylmora_cookies":
            let res = try await controller.listCookies(url: args["url"] as? String, tabId: tabId)
            let data = try JSONSerialization.data(withJSONObject: Self.sanitizeJSONValue(res), options: [.prettyPrinted])
            return String(data: data, encoding: .utf8) ?? "{}"

        case "kylmora_batch":
            let res = try await executeRPCMethod(name: "kylmora.batch", params: args)
            let data = try JSONSerialization.data(withJSONObject: Self.sanitizeJSONValue(res), options: [.prettyPrinted])
            return String(data: data, encoding: .utf8) ?? "{}"

        case "kylmora_status":
            let status = controller.status()
            return "control: \(status["control"] ?? "") \(status["detail"] ?? "")\nagent tab: \(status["agentTab"] ?? "")"

        default:
            throw AgentError.invalidTarget("Unknown tool: \(name)")
        }
    }
}
