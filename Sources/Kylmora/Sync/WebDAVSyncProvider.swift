import Foundation

/// Handles cross-device synchronization over standard WebDAV / Nextcloud / ownCloud servers.
actor WebDAVSyncProvider {
    enum WebDAVError: LocalizedError {
        case invalidURL
        case unauthorized
        case httpError(statusCode: Int, message: String)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The WebDAV server URL is invalid."
            case .unauthorized:
                return "WebDAV authentication failed. Check your username and password."
            case .httpError(let code, let msg):
                return "WebDAV HTTP Error \(code): \(msg)"
            case .networkError(let err):
                return "Network error: \(err.localizedDescription)"
            }
        }
    }

    private let serverURL: URL
    private let username: String
    private let password: String
    private let session: URLSession

    init(serverURL: URL, username: String, password: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.session = session
    }

    private var authHeader: String? {
        guard !username.isEmpty else { return nil }
        let loginString = "\(username):\(password)"
        guard let loginData = loginString.data(using: .utf8) else { return nil }
        return "Basic \(loginData.base64EncodedString())"
    }

    private func makeRequest(url: URL, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Verifies connectivity and credentials with the WebDAV endpoint.
    func testConnection() async throws -> Bool {
        let request = makeRequest(url: serverURL, method: "PROPFIND")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw WebDAVError.unauthorized
        }
        // 207 Multi-Status, 200 OK, or 404 (if directory doesn't exist yet but auth succeeded)
        return (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207 || httpResponse.statusCode == 404
    }

    /// Creates directory collection if needed.
    func createDirectory(at url: URL) async {
        let request = makeRequest(url: url, method: "MKCOL")
        _ = try? await session.data(for: request)
    }

    /// Uploads this device's sync archive and updates the manifest.
    func saveLocalArchive(_ archive: SyncArchive, passphrase: String?) async throws {
        // 1. Ensure devices/ collection exists
        let devicesURL = serverURL.appending(path: "devices")
        await createDirectory(at: serverURL)
        await createDirectory(at: devicesURL)

        // 2. Encode archive & optionally encrypt
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var payload = try encoder.encode(archive)
        if let passphrase, !passphrase.isEmpty {
            payload = try SyncCrypto.encrypt(payload, passphrase: passphrase)
        }

        // 3. PUT device archive
        let deviceURL = devicesURL.appending(path: "device-\(archive.deviceID.uuidString).json")
        let putRequest = makeRequest(url: deviceURL, method: "PUT", body: payload)
        let (_, putResponse) = try await session.data(for: putRequest)
        if let http = putResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebDAVError.httpError(statusCode: http.statusCode, message: "Failed to upload sync archive")
        }

        // 4. Update manifest.json
        var manifest = await fetchManifest()
        manifest.devices[archive.deviceID.uuidString] = FileUbiquitySyncProvider.Manifest.DeviceEntry(
            id: archive.deviceID,
            name: archive.deviceName,
            lastUpdated: archive.exportedAt
        )
        if let manifestData = try? encoder.encode(manifest) {
            let manifestURL = serverURL.appending(path: "manifest.json")
            let manifestRequest = makeRequest(url: manifestURL, method: "PUT", body: manifestData)
            _ = try? await session.data(for: manifestRequest)
        }
    }

    /// Fetches remote peer archives from the WebDAV server.
    func fetchRemoteArchives(excludingDeviceID localID: UUID, passphrase: String?) async throws -> [SyncArchive] {
        let manifest = await fetchManifest()
        let remoteDeviceIDs = manifest.devices.keys.compactMap { UUID(uuidString: $0) }.filter { $0 != localID }

        var archives: [SyncArchive] = []
        let decoder = JSONDecoder()

        for id in remoteDeviceIDs {
            let deviceURL = serverURL.appending(path: "devices/device-\(id.uuidString).json")
            let request = makeRequest(url: deviceURL, method: "GET")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                continue
            }

            do {
                let decrypted = try SyncCrypto.decrypt(data, passphrase: passphrase)
                if let archive = try? decoder.decode(SyncArchive.self, from: decrypted) {
                    archives.append(archive)
                }
            } catch {
                // If decryption fails due to wrong passphrase, ignore or log
                continue
            }
        }

        return archives.sorted { $0.exportedAt > $1.exportedAt }
    }

    private func fetchManifest() async -> FileUbiquitySyncProvider.Manifest {
        let manifestURL = serverURL.appending(path: "manifest.json")
        let request = makeRequest(url: manifestURL, method: "GET")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let manifest = try? JSONDecoder().decode(FileUbiquitySyncProvider.Manifest.self, from: data) else {
            return FileUbiquitySyncProvider.Manifest()
        }
        return manifest
    }
}
