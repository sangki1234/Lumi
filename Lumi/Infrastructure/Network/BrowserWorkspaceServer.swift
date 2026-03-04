//
//  BrowserWorkspaceServer.swift
//  LumiAgent (macOS)
//
//  Lightweight HTTP server on port 47287 that serves:
//    1. A standalone browser panel page (/panel) — the user opens this as a
//       dedicated browser tab.  It shows the tile grid and lets users control
//       which URLs each agent tile is browsing.
//    2. A JSON API used by the panel page to read state and issue commands.
//
//  Endpoints
//  ─────────
//  GET  /ping
//  GET  /panel                        — standalone HTML control panel
//  GET  /api/layout                   — canvas & tile geometry + agent assignments
//  GET  /api/tile-screenshot?agentId= — JPEG of the agent's 4 000×4 000 tile
//  POST /api/navigate?agentId=&url=   — navigate tile to URL
//  POST /api/release?agentId=         — close & release tile
//
//  All responses include CORS headers so the panel page can be served from
//  any origin (e.g. file://, chrome-extension://).
//

#if os(macOS)
import Foundation
import Network
import AppKit

// MARK: - Browser Workspace Server

@MainActor
public final class BrowserWorkspaceServer {

    // MARK: - Singleton

    public static let shared = BrowserWorkspaceServer()

    // MARK: - Constants

    static let port: UInt16 = 47287

    // MARK: - State

    @Published public private(set) var isRunning: Bool = false

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
            let l = try NWListener(using: params,
                                   on: NWEndpoint.Port(integerLiteral: Self.port))
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:    self?.isRunning = true
                    case .failed, .cancelled: self?.isRunning = false; self?.listener = nil
                    default: break
                    }
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { connection.cancel(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let raw = String(data: data, encoding: .utf8) ?? ""
                let response = self.dispatch(raw)
                connection.send(content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    // MARK: - HTTP dispatch

    private func dispatch(_ raw: String) -> Data {
        let line  = raw.components(separatedBy: "\r\n").first ?? ""
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { return errorResponse(400, "Bad Request") }

        let method = parts[0].uppercased()
        let (path, query) = parsePath(parts[1])

        switch (method, path) {
        case ("GET",  "/ping"):                  return jsonResponse(200, ["ok": true])
        case ("GET",  "/panel"):                 return htmlResponse(Self.panelHTML())
        case ("GET",  "/api/layout"):            return handleLayout()
        case ("GET",  "/api/tile-screenshot"):   return handleTileScreenshot(query: query)
        case ("POST", "/api/navigate"):          return handleNavigate(query: query)
        case ("POST", "/api/release"):           return handleRelease(query: query)
        case ("OPTIONS", _):                     return corsResponse()
        default:                                 return errorResponse(404, "Not Found")
        }
    }

    // MARK: - Endpoint handlers

    private func handleLayout() -> Data {
        let vdm = VirtualDisplayManager.shared
        let canvas: [String: Any] = [
            "width":       Int(VirtualDisplayManager.canvasSize.width),
            "height":      Int(VirtualDisplayManager.canvasSize.height),
            "tileWidth":   Int(VirtualDisplayManager.tileSize.width),
            "tileHeight":  Int(VirtualDisplayManager.tileSize.height),
            "tilesPerRow": VirtualDisplayManager.tilesPerRow,
            "virtualDisplay": vdm.virtualDisplayID != nil,
            "virtualDisplayID": vdm.virtualDisplayID.map { Int($0) } as Any
        ]

        let agentsState = AppState.shared?.agents ?? []
        let tilesList: [[String: Any]] = vdm.tiles.values.map { tile in
            let agent = agentsState.first { $0.id == tile.id }
            return [
                "agentId":   tile.id.uuidString,
                "agentName": agent?.name ?? tile.id.uuidString.prefix(8),
                "slot":      tile.slot,
                "tileOriginX": Int(tile.tileOrigin.x),
                "tileOriginY": Int(tile.tileOrigin.y),
                "currentURL":  tile.currentURL ?? ""
            ]
        }.sorted { ($0["slot"] as? Int ?? 0) < ($1["slot"] as? Int ?? 0) }

        return jsonResponse(200, ["canvas": canvas, "tiles": tilesList])
    }

    private func handleTileScreenshot(query: [String: String]) -> Data {
        guard let idStr = query["agentId"],
              let agentID = UUID(uuidString: idStr) else {
            return errorResponse(400, "Missing agentId")
        }
        let maxWidth = query["maxWidth"].flatMap { Double($0) }.map { CGFloat($0) } ?? 1440

        guard let jpeg = VirtualDisplayManager.shared.captureAgentTile(
            agentID: agentID, maxWidth: maxWidth) else {
            return errorResponse(404, "No tile found for agent \(idStr)")
        }

        let header = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n"
                   + corsHeaders() + "Connection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(jpeg)
        return response
    }

    private func handleNavigate(query: [String: String]) -> Data {
        guard let idStr = query["agentId"],
              let agentID = UUID(uuidString: idStr),
              let urlString = query["url"] else {
            return errorResponse(400, "Missing agentId or url")
        }
        VirtualDisplayManager.shared.navigate(agentID: agentID, to: urlString)
        return jsonResponse(200, ["ok": true, "agentId": idStr, "url": urlString])
    }

    private func handleRelease(query: [String: String]) -> Data {
        guard let idStr = query["agentId"],
              let agentID = UUID(uuidString: idStr) else {
            return errorResponse(400, "Missing agentId")
        }
        VirtualDisplayManager.shared.releaseTile(for: agentID)
        return jsonResponse(200, ["ok": true])
    }

    // MARK: - Helpers

    private func parsePath(_ raw: String) -> (String, [String: String]) {
        let comps = raw.components(separatedBy: "?")
        var query: [String: String] = [:]
        if comps.count > 1 {
            for pair in comps[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0].removingPercentEncoding ?? kv[0]] =
                        kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        return (comps[0], query)
    }

    private func corsHeaders() -> String {
        "Access-Control-Allow-Origin: *\r\n"
      + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
      + "Access-Control-Allow-Headers: Content-Type\r\n"
    }

    private func jsonResponse(_ status: Int, _ body: Any) -> Data {
        let bd = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let h = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\n"
              + "Content-Length: \(bd.count)\r\n" + corsHeaders() + "Connection: close\r\n\r\n"
        var r = h.data(using: .utf8) ?? Data()
        r.append(bd)
        return r
    }

    private func htmlResponse(_ html: String) -> Data {
        let bd = html.data(using: .utf8) ?? Data()
        let h = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
              + "Content-Length: \(bd.count)\r\n" + corsHeaders() + "Connection: close\r\n\r\n"
        var r = h.data(using: .utf8) ?? Data()
        r.append(bd)
        return r
    }

    private func errorResponse(_ status: Int, _ msg: String) -> Data {
        let bd = (try? JSONSerialization.data(withJSONObject: ["error": msg])) ?? Data()
        let h = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\n"
              + "Content-Length: \(bd.count)\r\n" + corsHeaders() + "Connection: close\r\n\r\n"
        var r = h.data(using: .utf8) ?? Data()
        r.append(bd)
        return r
    }

    private func corsResponse() -> Data {
        let h = "HTTP/1.1 204 No Content\r\n" + corsHeaders() + "Connection: close\r\n\r\n"
        return h.data(using: .utf8) ?? Data()
    }

    // MARK: - Standalone panel HTML

    /// The full HTML of the browser panel page served at /panel.
    /// Users open http://localhost:47287/panel as a standalone browser tab.
    private static func panelHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Lumi — Browser Workspace</title>
        <style>
          *{box-sizing:border-box;margin:0;padding:0}
          body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
               background:#0d0d0d;color:#e0e0e0;min-height:100vh}
          header{display:flex;align-items:center;gap:10px;padding:14px 20px;
                 background:#161616;border-bottom:1px solid #2a2a2a}
          header h1{font-size:17px;font-weight:600}
          .badge{font-size:11px;padding:2px 8px;border-radius:20px;
                 background:#1e3a5f;color:#60a5fa}
          .status{font-size:12px;color:#6b7280;margin-left:auto}
          .status.ok{color:#34d399}
          #grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));
                gap:16px;padding:20px}
          .tile{background:#161616;border:1px solid #2a2a2a;border-radius:10px;
                overflow:hidden}
          .tile-header{display:flex;align-items:center;gap:8px;padding:10px 12px;
                       background:#1a1a1a;border-bottom:1px solid #2a2a2a}
          .tile-dot{width:8px;height:8px;border-radius:50%;background:#34d399}
          .tile-name{font-size:13px;font-weight:500;flex:1;overflow:hidden;
                     text-overflow:ellipsis;white-space:nowrap}
          .tile-slot{font-size:11px;color:#6b7280}
          .tile-img{width:100%;display:block;background:#0d0d0d;min-height:140px;
                    object-fit:cover}
          .tile-footer{padding:8px 12px;display:flex;gap:6px}
          .tile-url{flex:1;padding:4px 8px;background:#0d0d0d;border:1px solid #2a2a2a;
                    border-radius:6px;color:#e0e0e0;font-size:12px}
          .tile-url:focus{outline:none;border-color:#3b82f6}
          .go-btn{padding:4px 10px;background:#3b82f6;color:#fff;border:none;
                  border-radius:6px;cursor:pointer;font-size:12px}
          .go-btn:hover{background:#2563eb}
          .empty{grid-column:1/-1;text-align:center;padding:60px 20px;color:#4b5563}
          .empty svg{margin-bottom:12px;opacity:.4}
          .canvas-info{padding:8px 20px;background:#111;border-bottom:1px solid #2a2a2a;
                       font-size:12px;color:#6b7280;display:flex;gap:16px}
        </style>
        </head>
        <body>
        <header>
          <svg width="22" height="22" viewBox="0 0 22 22" fill="none">
            <circle cx="11" cy="11" r="10" fill="#3b82f6" opacity=".15"/>
            <circle cx="11" cy="11" r="5"  fill="#3b82f6"/>
          </svg>
          <h1>Lumi Browser Workspace</h1>
          <span class="badge">20 000 × 20 000</span>
          <span class="status" id="connStatus">Connecting…</span>
        </header>
        <div class="canvas-info" id="canvasInfo">Loading layout…</div>
        <div id="grid"></div>

        <script>
        const BASE = 'http://localhost:47287';
        let layout = null;

        async function fetchLayout() {
          try {
            const r = await fetch(BASE + '/api/layout');
            if (!r.ok) return;
            layout = await r.json();
            document.getElementById('connStatus').textContent = 'Connected';
            document.getElementById('connStatus').className = 'status ok';
            const c = layout.canvas;
            document.getElementById('canvasInfo').textContent =
              `Canvas: ${c.width.toLocaleString()} × ${c.height.toLocaleString()} px  ·  ` +
              `Tile: ${c.tileWidth.toLocaleString()} × ${c.tileHeight.toLocaleString()} px  ·  ` +
              `Tiles per row: ${c.tilesPerRow}  ·  ` +
              (c.virtualDisplay ? `Virtual display: ${c.virtualDisplayID}` : 'Fallback off-screen mode');
            renderGrid();
          } catch {
            document.getElementById('connStatus').textContent = 'Lumi not running';
          }
        }

        function renderGrid() {
          const grid = document.getElementById('grid');
          if (!layout || !layout.tiles || layout.tiles.length === 0) {
            grid.innerHTML = '<div class="empty">' +
              '<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">' +
              '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/>' +
              '<rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/>' +
              '</svg><div>No agents have Browser Workspace enabled.</div>' +
              '<div style="margin-top:6px;font-size:12px">Enable it on an agent in Lumi → Browser Workspace.</div></div>';
            return;
          }
          grid.innerHTML = layout.tiles.map(tile => `
            <div class="tile" id="tile-${tile.agentId}">
              <div class="tile-header">
                <div class="tile-dot"></div>
                <div class="tile-name">${tile.agentName}</div>
                <div class="tile-slot">Slot ${tile.slot} · (${tile.tileOriginX}, ${tile.tileOriginY})</div>
              </div>
              <img class="tile-img" id="img-${tile.agentId}"
                   src="${BASE}/api/tile-screenshot?agentId=${tile.agentId}&t=${Date.now()}"
                   alt="tile screenshot" loading="lazy">
              <div class="tile-footer">
                <input class="tile-url" id="url-${tile.agentId}"
                       value="${tile.currentURL || ''}" placeholder="https://…"
                       onkeydown="if(event.key==='Enter')navigate('${tile.agentId}')">
                <button class="go-btn" onclick="navigate('${tile.agentId}')">Go</button>
              </div>
            </div>
          `).join('');
        }

        async function navigate(agentId) {
          const url = document.getElementById('url-' + agentId)?.value?.trim();
          if (!url) return;
          try {
            await fetch(BASE + '/api/navigate?agentId=' + agentId + '&url=' + encodeURIComponent(url),
                        { method: 'POST' });
            setTimeout(() => refreshScreenshot(agentId), 1500);
          } catch {}
        }

        function refreshScreenshot(agentId) {
          const img = document.getElementById('img-' + agentId);
          if (img) img.src = BASE + '/api/tile-screenshot?agentId=' + agentId + '&t=' + Date.now();
        }

        // Poll layout every 3 s, refresh screenshots every 5 s
        fetchLayout();
        setInterval(fetchLayout, 3000);
        setInterval(() => {
          if (!layout) return;
          layout.tiles.forEach(t => refreshScreenshot(t.agentId));
        }, 5000);
        </script>
        </body>
        </html>
        """
    }
}

#endif
