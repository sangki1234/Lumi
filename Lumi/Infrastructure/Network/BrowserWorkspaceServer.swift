//
//  BrowserWorkspaceServer.swift
//  LumiAgent (macOS)
//
//  Lightweight HTTP server on port 47287 that the Lumi browser extension
//  polls to display agent status and request screenshots.
//
//  Endpoints
//  ─────────
//  GET  /ping                    → {"ok":true}
//  GET  /agents                  → JSON list of agents and their workspace info
//  GET  /screenshot?agentId=<uuid>&maxWidth=<n>
//                                → JPEG image data (Content-Type: image/jpeg)
//  POST /assign?agentId=<uuid>&tabUrl=<url>
//                                → {"ok":true}
//  POST /release?agentId=<uuid>  → {"ok":true}
//
//  The extension connects to http://localhost:47287.  CORS is always allowed so
//  any browser origin can call these endpoints.
//

#if os(macOS)
import Foundation
import Network
import AppKit

// MARK: - Browser Workspace Server

/// Singleton HTTP server that bridges the Lumi browser extension with the
/// native app.
@MainActor
public final class BrowserWorkspaceServer {

    // MARK: - Singleton

    public static let shared = BrowserWorkspaceServer()

    // MARK: - Constants

    static let port: UInt16 = 47287

    // MARK: - State

    @Published public private(set) var isRunning: Bool = false
    /// agentID → active tab URL
    @Published public private(set) var assignedTabs: [UUID: String] = [:]

    // MARK: - Private

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.lumiagent.browser-ws", qos: .userInitiated)

    private init() {}

    // MARK: - Start / Stop

    public func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: Self.port))
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    if case .ready = state { self?.isRunning = true }
                    if case .failed = state { self?.isRunning = false; self?.listener = nil }
                    if case .cancelled = state { self?.isRunning = false; self?.listener = nil }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in self?.handle(conn) }
            }
            self.listener = l
            l.start(queue: queue)
            print("[BrowserWorkspaceServer] Listening on port \(Self.port)")
        } catch {
            print("[BrowserWorkspaceServer] Failed to start: \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel(); return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let request = String(data: data, encoding: .utf8) ?? ""
                let response = self.handleHTTPRequest(request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    // MARK: - HTTP Request Dispatch

    private func handleHTTPRequest(_ raw: String) -> Data {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return errorResponse(400, "Bad Request") }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return errorResponse(400, "Bad Request") }

        let method = parts[0].uppercased()
        let fullPath = parts[1]
        let (path, queryItems) = parsePath(fullPath)

        switch (method, path) {

        case ("GET", "/ping"):
            return jsonResponse(200, ["ok": true])

        case ("GET", "/agents"):
            return handleAgents()

        case ("GET", "/screenshot"):
            return handleScreenshot(queryItems: queryItems)

        case ("POST", "/assign"):
            return handleAssign(queryItems: queryItems)

        case ("POST", "/release"):
            return handleRelease(queryItems: queryItems)

        case ("OPTIONS", _):
            // CORS pre-flight
            return corsResponse()

        default:
            return errorResponse(404, "Not Found")
        }
    }

    // MARK: - Endpoint Handlers

    private func handleAgents() -> Data {
        let displays = VirtualDisplayManager.shared.agentDisplays
        let appState = AppState.shared

        var list: [[String: Any]] = []
        let agents = appState?.agents ?? []
        for agent in agents {
            guard agent.configuration.browserWorkspaceEnabled else { continue }
            var entry: [String: Any] = [
                "id": agent.id.uuidString,
                "name": agent.name,
                "status": agent.status.rawValue,
                "browserWorkspaceEnabled": true
            ]
            if let display = displays[agent.id] {
                entry["hasWorkspace"] = true
                entry["workspaceSize"] = [
                    "width": Int(display.size.width),
                    "height": Int(display.size.height)
                ]
                entry["isVirtualDisplay"] = display.isVirtualDisplay
                if let tabURL = assignedTabs[agent.id] {
                    entry["assignedTabUrl"] = tabURL
                }
            } else {
                entry["hasWorkspace"] = false
            }
            list.append(entry)
        }
        return jsonResponse(200, ["agents": list])
    }

    private func handleScreenshot(queryItems: [String: String]) -> Data {
        guard let idString = queryItems["agentId"],
              let agentID = UUID(uuidString: idString) else {
            return errorResponse(400, "Missing agentId")
        }
        let maxWidth = queryItems["maxWidth"].flatMap { Double($0) }.map { CGFloat($0) } ?? 1440

        guard let jpeg = VirtualDisplayManager.shared.captureWorkspace(for: agentID, maxWidth: maxWidth) else {
            return errorResponse(404, "No workspace or capture failed for agent \(idString)")
        }

        let status = "HTTP/1.1 200 OK\r\n"
        let headers = "Content-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = (status + headers).data(using: .utf8) ?? Data()
        response.append(jpeg)
        return response
    }

    private func handleAssign(queryItems: [String: String]) -> Data {
        guard let idString = queryItems["agentId"],
              let agentID = UUID(uuidString: idString) else {
            return errorResponse(400, "Missing agentId")
        }
        let tabURL = queryItems["tabUrl"] ?? ""
        assignedTabs[agentID] = tabURL
        // Ensure workspace exists.
        VirtualDisplayManager.shared.createWorkspace(for: agentID)
        return jsonResponse(200, ["ok": true, "agentId": idString, "tabUrl": tabURL])
    }

    private func handleRelease(queryItems: [String: String]) -> Data {
        guard let idString = queryItems["agentId"],
              let agentID = UUID(uuidString: idString) else {
            return errorResponse(400, "Missing agentId")
        }
        assignedTabs.removeValue(forKey: agentID)
        return jsonResponse(200, ["ok": true])
    }

    // MARK: - Helpers

    private func parsePath(_ raw: String) -> (path: String, query: [String: String]) {
        let components = raw.components(separatedBy: "?")
        let path = components[0]
        var query: [String: String] = [:]
        if components.count > 1 {
            for pair in components[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    let key = kv[0].removingPercentEncoding ?? kv[0]
                    let val = kv[1].removingPercentEncoding ?? kv[1]
                    query[key] = val
                }
            }
        }
        return (path, query)
    }

    private func jsonResponse(_ status: Int, _ body: Any) -> Data {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        let header = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(bodyData)
        return response
    }

    private func errorResponse(_ status: Int, _ message: String) -> Data {
        let body = "{\"error\":\"\(message)\"}".data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(body)
        return response
    }

    private func corsResponse() -> Data {
        let header = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
        return header.data(using: .utf8) ?? Data()
    }
}

#endif
