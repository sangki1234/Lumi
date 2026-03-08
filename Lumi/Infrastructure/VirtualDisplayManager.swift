//
//  VirtualDisplayManager.swift
//  LumiAgent
//
//  Single shared 10 240 × 10 240 virtual canvas, tiled into 2 048 × 2 048
//  agent slots.  Each agent's slot is backed by a WKWebView NSWindow placed
//  at the tile's origin so the agent can browse, interact, and screenshot its
//  own tile independently.
//
//  Canvas layout (tiles per row = 5, rows = 5, max 25 concurrent agents)
//  ────────────────────────────────────────────────────────────────────────
//  slot 0  : origin (    0,    0)   slot 1  : origin ( 2048,    0) …
//  slot 5  : origin (    0, 2048)   slot 6  : origin ( 2048, 2048) …
//  …
//
//  Virtual display strategy
//  ────────────────────────
//  macOS 12.4+ ships CGVirtualDisplay which genuinely registers a fake screen
//  with the WindowServer — apps see it as a real monitor and windows can be
//  moved there.  This needs the restricted
//  `com.apple.developer.virtual-displays` entitlement.
//
//  When that entitlement is absent we fall back to placing browser windows at
//  large off-screen coordinates that match the same tile grid geometry.
//  screencapture -l <windowID> can capture any window regardless of where it
//  is positioned on screen, so the agent capture path works in both modes.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import WebKit
import Combine
import Quartz

// MARK: - Missing CoreGraphics Symbols
// CGVirtualDisplay APIs are available in macOS 12.4+ but are sometimes missing
// from the Swift overlay in certain SDK versions.

@objc(CGVirtualDisplayDescriptor)
internal class CGVirtualDisplayDescriptor: NSObject {
    @objc var name: String?
    @objc var sizeInMillimeters: CGSize = .zero
    @objc var queue: DispatchQueue?
    @objc var resizeSensorCallback: ((UInt32, UInt32, UInt32) -> Void)?
}

@objc(CGVirtualDisplaySettings)
internal class CGVirtualDisplaySettings: NSObject {
    @objc var hiDPI: Bool = false
    @objc var modes: [NSObject] = []
}

@objc(CGVirtualDisplayMode)
internal class CGVirtualDisplayMode: NSObject {
    @objc let width: UInt32
    @objc let height: UInt32
    @objc let refreshRate: Double

    @objc init(width: UInt32, height: UInt32, refreshRate: Double) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        super.init()
    }
}

@objc(CGVirtualDisplay)
internal class CGVirtualDisplay: NSObject {
    @objc init?(descriptor: CGVirtualDisplayDescriptor) {
        // Shim path: no real virtual display backing is available.
        return nil
    }

    @objc func apply(_ settings: CGVirtualDisplaySettings) -> Int {
        // Non-zero indicates failure in CoreGraphics-style APIs.
        return -1
    }

    @objc var displayID: UInt32 { 0 }
}

// MARK: - Agent Tile

/// All the information about one agent's 2 048 × 2 048 tile on the canvas.
public struct AgentTile: Identifiable, Sendable {
    public let id: UUID           // agent ID
    public let slot: Int          // 0-based grid slot
    public let tileOrigin: CGPoint // origin within the shared virtual canvas
    public let windowID: CGWindowID
    public var currentURL: String?
}

/// Snapshot of one browser tile's current navigation state.
public struct BrowserTileState: Sendable {
    public let agentID: UUID
    public let slot: Int
    public let tileOriginX: Int
    public let tileOriginY: Int
    public let assignedURL: String?
    public let loadedURL: String?
    public let pageTitle: String?
    public let canGoBack: Bool
    public let canGoForward: Bool
}

/// Snapshot of the visible page content in a browser tile.
public struct BrowserPageSnapshot: Sendable {
    public let title: String
    public let url: String
    public let text: String
}

// MARK: - Virtual Display Manager

/// Singleton that owns the shared virtual canvas and all per-agent browser tiles.
@MainActor
public final class VirtualDisplayManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = VirtualDisplayManager()

    // MARK: - Canvas constants

    /// Number of tiles in each row.
    public static let tilesPerRow = 5
    /// Number of tile rows.
    public static let tileRows = 5
    /// Size of each agent's browser tile.
    public static let tileSize = CGSize(width: 2_048, height: 2_048)
    /// Total size of the shared virtual canvas.
    public static let canvasSize = CGSize(
        width: tileSize.width * CGFloat(tilesPerRow),
        height: tileSize.height * CGFloat(tileRows)
    )

    // MARK: - Published state

    @Published public private(set) var tiles: [UUID: AgentTile] = [:]
    @Published public private(set) var virtualDisplayID: UInt32? = nil

    // MARK: - Private

    /// The single large NSWindow that represents the canvas when CGVirtualDisplay
    /// is unavailable (kept alive so screencapture can find it).
    private var canvasWindow: NSWindow?
    /// Backing browser windows, keyed by agent ID.
    /// Strong references are intentional: VirtualDisplayManager owns these windows;
    /// they are explicitly closed and removed in releaseTile(for:).
    private var browserWindows: [UUID: NSWindow] = [:]
    /// Slot occupancy: slot index → agent ID.
    private var occupiedSlots: [Int: UUID] = [:]
    /// Held reference to the CGVirtualDisplay object (ARC keeps it alive).
    private var virtualDisplayObject: AnyObject?

    private init() {}

    // MARK: - Canvas bootstrap

    /// Ensures the shared virtual canvas exists.  Must be called once at startup.
    public func prepareCanvas() {
        guard canvasWindow == nil && virtualDisplayID == nil else { return }

        if let id = tryCreateCGVirtualDisplay() {
            virtualDisplayID = id
            print("[VirtualDisplayManager] Virtual display \(id) active (\(Self.canvasSize.width)×\(Self.canvasSize.height))")
        } else {
            createFallbackCanvasWindow()
        }
    }

    // MARK: - Tile management

    /// Assign the next free tile to `agentID` (or return the existing tile).
    /// Opens a 2 048 × 2 048 WKWebView window at the tile origin.
    /// - Parameter url: Optional starting URL to load in the browser tile.
    @discardableResult
    public func assignTile(to agentID: UUID, url: String? = nil) -> AgentTile? {
        if let existing = tiles[agentID] {
            if let url {
                _ = navigate(agentID: agentID, to: url)
            }
            return existing
        }

        guard let slot = nextFreeSlot() else {
            print("[VirtualDisplayManager] All \(Self.tilesPerRow * Self.tilesPerRow) slots occupied")
            return nil
        }

        let origin = tileOrigin(for: slot)
        // Ensure every new tile starts on a real page instead of the placeholder,
        // so users always see a URL and agents have a concrete browser state.
        let initialURL = Self.normalizeURLString(url) ?? "https://example.com"
        let window = createBrowserWindow(at: origin, agentID: agentID, url: initialURL)
        // windowNumber is negative when the window is off-screen; guard against
        // the Swift UInt32 overflow crash that would result from a blind cast.
        let rawNum = window.windowNumber
        let wid: CGWindowID = rawNum > 0 ? CGWindowID(rawNum) : 0

        let tile = AgentTile(
            id: agentID,
            slot: slot,
            tileOrigin: origin,
            windowID: wid,
            currentURL: initialURL
        )
        // Avoid in-place mutation on @Published dictionary storage.
        var nextTiles = tiles
        nextTiles[agentID] = tile
        tiles = nextTiles
        occupiedSlots[slot] = agentID
        browserWindows[agentID] = window
        print("[VirtualDisplayManager] Agent \(agentID) → slot \(slot) origin \(origin) window \(wid)")
        return tile
    }

    /// Navigate the agent's browser tile to a new URL.
    @discardableResult
    public func navigate(agentID: UUID, to urlString: String) -> Bool {
        guard let url = Self.normalizedURL(from: urlString) else { return false }
        let normalizedString = url.absoluteString

        // Auto-assign a tile when missing so navigation commands remain usable.
        if browserWindows[agentID] == nil {
            return assignTile(to: agentID, url: normalizedString) != nil
        }

        guard let webView = webView(for: agentID) else { return false }
        webView.load(URLRequest(url: url))

        // Avoid in-place mutation on @Published dictionary storage.
        var nextTiles = tiles
        if var tile = nextTiles[agentID] {
            tile.currentURL = normalizedString
            nextTiles[agentID] = tile
            tiles = nextTiles
        }
        return true
    }

    /// Return state for one browser tile.
    public func browserTileState(agentID: UUID) -> BrowserTileState? {
        guard let tile = tiles[agentID] else { return nil }
        let webView = webView(for: agentID)
        return BrowserTileState(
            agentID: agentID,
            slot: tile.slot,
            tileOriginX: Int(tile.tileOrigin.x),
            tileOriginY: Int(tile.tileOrigin.y),
            assignedURL: tile.currentURL,
            loadedURL: webView?.url?.absoluteString,
            pageTitle: webView?.title,
            canGoBack: webView?.canGoBack ?? false,
            canGoForward: webView?.canGoForward ?? false
        )
    }

    /// Return state for all assigned browser tiles.
    public func listBrowserTileStates() -> [BrowserTileState] {
        tiles.keys.compactMap { browserTileState(agentID: $0) }
            .sorted { $0.slot < $1.slot }
    }

    /// Reload a browser tile.
    @discardableResult
    public func reload(agentID: UUID) -> Bool {
        guard let webView = webView(for: agentID) else { return false }
        webView.reload()
        return true
    }

    /// Navigate backward in browser history.
    @discardableResult
    public func goBack(agentID: UUID) -> Bool {
        guard let webView = webView(for: agentID), webView.canGoBack else { return false }
        webView.goBack()
        return true
    }

    /// Navigate forward in browser history.
    @discardableResult
    public func goForward(agentID: UUID) -> Bool {
        guard let webView = webView(for: agentID), webView.canGoForward else { return false }
        webView.goForward()
        return true
    }

    /// Read title/URL/visible text from the tile's current page.
    public func readBrowserPage(agentID: UUID, maxChars: Int = 12_000) async -> BrowserPageSnapshot? {
        guard let webView = webView(for: agentID) else { return nil }

        let script = """
        (function() {
          const title = document.title || "";
          const url = window.location.href || "";
          const text = document.body ? (document.body.innerText || "") : "";
          return JSON.stringify({ title, url, text });
        })();
        """

        let maxLen = max(500, min(maxChars, 200_000))
        let fallbackURL = webView.url?.absoluteString ?? ""
        let fallbackTitle = webView.title ?? ""

        guard let raw = try? await evaluateJavaScript(script, in: webView),
              let payload = raw as? String,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BrowserPageSnapshot(
                title: fallbackTitle,
                url: fallbackURL,
                text: ""
            )
        }

        let title = (json["title"] as? String) ?? fallbackTitle
        let url = (json["url"] as? String) ?? fallbackURL
        let fullText = (json["text"] as? String) ?? ""
        let text = fullText.count > maxLen ? String(fullText.prefix(maxLen)) : fullText
        return BrowserPageSnapshot(title: title, url: url, text: text)
    }

    /// Click a point inside the visible browser tile viewport using JS-dispatched
    /// mouse events. Coordinates are relative to the tile viewport (top-left 0,0).
    public func clickBrowserTile(
        agentID: UUID,
        x: Int,
        y: Int,
        button: String = "left",
        clicks: Int = 1
    ) async -> String? {
        guard let webView = webView(for: agentID) else { return nil }

        let boundedX = max(0, min(Int(Self.tileSize.width) - 1, x))
        let boundedY = max(0, min(Int(Self.tileSize.height) - 1, y))
        let clickCount = max(1, min(3, clicks))
        let jsButton: Int
        switch button.lowercased() {
        case "right": jsButton = 2
        case "middle": jsButton = 1
        default: jsButton = 0
        }

        let script = """
        (function() {
          const x = \(boundedX);
          const y = \(boundedY);
          const button = \(jsButton);
          const clicks = \(clickCount);
          const target = document.elementFromPoint(x, y);
          if (!target) {
            return JSON.stringify({ ok: false, error: "No element at coordinates", x, y });
          }

          const opts = {
            bubbles: true,
            cancelable: true,
            composed: true,
            view: window,
            clientX: x,
            clientY: y,
            button: button
          };

          target.dispatchEvent(new MouseEvent("mousemove", opts));
          for (let i = 0; i < clicks; i++) {
            target.dispatchEvent(new MouseEvent("mousedown", opts));
            target.dispatchEvent(new MouseEvent("mouseup", opts));
            target.dispatchEvent(new MouseEvent("click", opts));
          }
          if (clicks >= 2) {
            target.dispatchEvent(new MouseEvent("dblclick", opts));
          }
          if (typeof target.focus === "function") target.focus();

          const text = (target.innerText || target.textContent || "").trim().slice(0, 120);
          return JSON.stringify({
            ok: true,
            x, y,
            tag: target.tagName || "",
            id: target.id || "",
            className: target.className || "",
            href: target.href || "",
            text
          });
        })();
        """

        guard let raw = try? await evaluateJavaScript(script, in: webView),
              let payload = raw as? String,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Click dispatched at (\(boundedX), \(boundedY))."
        }

        if (json["ok"] as? Bool) == false {
            let message = (json["error"] as? String) ?? "No clickable element found"
            return "Click failed at (\(boundedX), \(boundedY)): \(message)"
        }

        let tag = (json["tag"] as? String) ?? "element"
        let text = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Clicked \(tag) at (\(boundedX), \(boundedY))."
        }
        return "Clicked \(tag) at (\(boundedX), \(boundedY)) — \"\(text)\"."
    }

    /// Type text into the active element (or first editable element) inside the
    /// browser tile viewport. Optionally submits the active form.
    public func typeInBrowserTile(
        agentID: UUID,
        text: String,
        submit: Bool = false,
        replace: Bool = false
    ) async -> String? {
        guard let webView = webView(for: agentID) else { return nil }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let script = """
        (function() {
          const text = "\(escaped)";
          const submit = \(submit ? "true" : "false");
          const replace = \(replace ? "true" : "false");

          function isEditable(el) {
            if (!el) return false;
            if (el.isContentEditable) return true;
            const tag = (el.tagName || "").toLowerCase();
            if (tag === "textarea") return true;
            if (tag === "input") {
              const t = (el.type || "text").toLowerCase();
              return !["button","submit","checkbox","radio","file","hidden","image","range","color","date","datetime-local","month","time","week"].includes(t);
            }
            return false;
          }

          let el = document.activeElement;
          if (!isEditable(el)) {
            el = document.querySelector('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea, [contenteditable=""], [contenteditable="true"]');
            if (el && typeof el.focus === "function") el.focus();
          }
          if (!isEditable(el)) {
            return JSON.stringify({ ok: false, error: "No editable element found" });
          }

          if (el.isContentEditable) {
            if (replace) {
              el.textContent = text;
            } else {
              el.textContent = (el.textContent || "") + text;
            }
          } else {
            const curr = String(el.value || "");
            el.value = replace ? text : (curr + text);
          }

          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));

          if (submit) {
            if (el.form && typeof el.form.requestSubmit === "function") {
              el.form.requestSubmit();
            } else if (el.form) {
              el.form.submit();
            } else {
              el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true }));
              el.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", bubbles: true }));
            }
          }

          const tag = el.tagName || "";
          const id = el.id || "";
          return JSON.stringify({ ok: true, tag, id, submit, chars: text.length });
        })();
        """

        guard let raw = try? await evaluateJavaScript(script, in: webView),
              let payload = raw as? String,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Typed text into browser tile."
        }

        if (json["ok"] as? Bool) == false {
            let message = (json["error"] as? String) ?? "No editable field found"
            return "Typing failed: \(message)"
        }
        let tag = (json["tag"] as? String) ?? "element"
        return submit
            ? "Typed into \(tag) and submitted."
            : "Typed into \(tag)."
    }

    /// Send a keyboard event to the active element within a browser tile.
    public func pressBrowserTileKey(
        agentID: UUID,
        key: String,
        modifiers: [String] = []
    ) async -> String? {
        guard let webView = webView(for: agentID) else { return nil }
        let escapedKey = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let lowered = Set(modifiers.map { $0.lowercased() })
        let meta = lowered.contains("meta") || lowered.contains("cmd") || lowered.contains("command")
        let ctrl = lowered.contains("ctrl") || lowered.contains("control")
        let alt = lowered.contains("alt") || lowered.contains("option")
        let shift = lowered.contains("shift")

        let script = """
        (function() {
          const key = "\(escapedKey)";
          const target = document.activeElement || document.body || document.documentElement;
          const eventInit = {
            key: key,
            code: key.length === 1 ? "Key" + key.toUpperCase() : key,
            bubbles: true,
            cancelable: true,
            metaKey: \(meta ? "true" : "false"),
            ctrlKey: \(ctrl ? "true" : "false"),
            altKey: \(alt ? "true" : "false"),
            shiftKey: \(shift ? "true" : "false")
          };
          target.dispatchEvent(new KeyboardEvent("keydown", eventInit));
          target.dispatchEvent(new KeyboardEvent("keyup", eventInit));
          return JSON.stringify({ ok: true, key });
        })();
        """

        _ = try? await evaluateJavaScript(script, in: webView)
        return "Sent key '\(key)' to browser tile (modifiers: \(modifiers.joined(separator: "+")))."
    }

    /// Release an agent's tile, closing its browser window.
    public func releaseTile(for agentID: UUID) {
        if let tile = tiles[agentID] {
            occupiedSlots.removeValue(forKey: tile.slot)
        }
        browserWindows[agentID]?.close()
        browserWindows.removeValue(forKey: agentID)
        // Avoid in-place mutation on @Published dictionary storage.
        var nextTiles = tiles
        nextTiles.removeValue(forKey: agentID)
        tiles = nextTiles
    }

    // MARK: - Capture

    /// Capture the agent's browser tile window as JPEG data.
    /// `maxWidth` controls the output resolution; defaults to 1 440 px wide.
    public func captureAgentTile(agentID: UUID, maxWidth: CGFloat = 1440) -> Data? {
        guard let tile = tiles[agentID] else { return nil }
        if tile.windowID != 0, let jpeg = captureWindow(id: tile.windowID, maxWidth: maxWidth) {
            return jpeg
        }
        // Fallback for off-screen / invalid window-id cases: capture from the
        // live NSView backing the tile window directly.
        return captureTileView(agentID: agentID, maxWidth: maxWidth)
    }

    /// Async capture path intended for UI preview and HTTP screenshot APIs.
    /// Uses WKWebView native snapshot first (does not rely on screen capture
    /// permission), then falls back to window/view capture.
    public func captureAgentTilePreview(agentID: UUID, maxWidth: CGFloat = 1440) async -> Data? {
        guard tiles[agentID] != nil else { return nil }
        if let webSnapshot = await captureWebViewSnapshot(agentID: agentID, maxWidth: maxWidth) {
            return webSnapshot
        }
        return captureAgentTile(agentID: agentID, maxWidth: maxWidth)
    }

    // MARK: - Private: CGVirtualDisplay

    private func tryCreateCGVirtualDisplay() -> UInt32? {
        guard #available(macOS 12.4, *) else { return nil }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "Lumi Canvas"
        descriptor.sizeInMillimeters = CGSize(width: 527, height: 527)
        descriptor.queue = DispatchQueue.main
        descriptor.resizeSensorCallback = nil

        let settings = CGVirtualDisplaySettings()
        let mode = CGVirtualDisplayMode(
            width: UInt32(Self.canvasSize.width),
            height: UInt32(Self.canvasSize.height),
            refreshRate: 30
        )
        settings.hiDPI = false
        settings.modes = [mode]

        guard let vd = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        guard vd.apply(settings) == 0 else { return nil } // 0 is Success
        let id = vd.displayID
        guard id != kCGNullDirectDisplay else { return nil }

        virtualDisplayObject = vd
        return id
    }

    // MARK: - Private: fallback canvas NSWindow

    private func createFallbackCanvasWindow() {
        // A large borderless window placed far off-screen.  It acts as the
        // conceptual origin of the tile grid; browser windows are placed relative
        // to its top-left corner.
        let origin = CGPoint(x: canvasOffscreenOffset, y: canvasOffscreenOffset)
        let frame = CGRect(origin: origin, size: Self.canvasSize)
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = "Lumi Virtual Canvas"
        w.backgroundColor = NSColor(white: 0.06, alpha: 1)
        w.isOpaque = true
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.orderFront(nil)
        canvasWindow = w
        print("[VirtualDisplayManager] Fallback canvas window at \(origin)")
    }

    // MARK: - Private: browser tile window

    private func createBrowserWindow(at tileOriginOnCanvas: CGPoint,
                                     agentID: UUID,
                                     url: String?) -> NSWindow {
        // Absolute screen position: if we have a real virtual display, the tile
        // origin IS the screen coordinate on that display.  For the fallback we
        // offset by the canvas window's origin.
        let screenOrigin: CGPoint
        if virtualDisplayID != nil {
            screenOrigin = tileOriginOnCanvas
        } else {
            let canvasOrigin = CGPoint(x: canvasOffscreenOffset, y: canvasOffscreenOffset)
            screenOrigin = CGPoint(
                x: canvasOrigin.x + tileOriginOnCanvas.x,
                y: canvasOrigin.y + tileOriginOnCanvas.y
            )
        }

        let frame = CGRect(origin: screenOrigin, size: Self.tileSize)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumi Browser — \(agentID.uuidString.prefix(8))"
        window.isOpaque = true
        window.backgroundColor = .white
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Embed a WKWebView as the full content.
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.tileSize))
        webView.autoresizingMask = [.width, .height]
        if let urlString = url, let targetURL = URL(string: urlString) {
            webView.load(URLRequest(url: targetURL))
        } else {
            webView.loadHTMLString(Self.tileDefaultHTML(agentID: agentID), baseURL: nil)
        }
        window.contentView = webView
        window.orderFront(nil)
        return window
    }

    private func webView(for agentID: UUID) -> WKWebView? {
        guard let window = browserWindows[agentID] else { return nil }
        return window.contentView as? WKWebView
    }

    private func captureWebViewSnapshot(agentID: UUID, maxWidth: CGFloat) async -> Data? {
        guard let webView = webView(for: agentID) else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true

        let snapshot: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let snapshot else { return nil }

        if let cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return jpegData(from: cg, maxWidth: maxWidth)
        }
        if let tiff = snapshot.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cg = rep.cgImage {
            return jpegData(from: cg, maxWidth: maxWidth)
        }
        return nil
    }

    private func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result ?? NSNull())
                }
            }
        }
    }

    private static func normalizeURLString(_ value: String?) -> String? {
        guard let url = normalizedURL(from: value) else { return nil }
        return url.absoluteString
    }

    private static func normalizedURL(from rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: - Private: tile geometry

    /// Returns the tile origin (within the virtual canvas) for `slot`.
    private func tileOrigin(for slot: Int) -> CGPoint {
        let col = slot % Self.tilesPerRow
        let row = slot / Self.tilesPerRow
        return CGPoint(
            x: CGFloat(col) * Self.tileSize.width,
            y: CGFloat(row) * Self.tileSize.height
        )
    }

    /// Returns the next unoccupied slot index, or nil if all slots are taken.
    private func nextFreeSlot() -> Int? {
        let maxSlots = Self.tilesPerRow * Self.tileRows
        return (0 ..< maxSlots).first { occupiedSlots[$0] == nil }
    }

    /// Off-screen coordinate used as the canvas origin in fallback mode.
    /// Large enough that no physical display will ever reach it.
    private var canvasOffscreenOffset: CGFloat { 50_000 }

    // MARK: - Private: window capture

    private func captureTileView(agentID: UUID, maxWidth: CGFloat) -> Data? {
        guard let view = browserWindows[agentID]?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)

        if let cg = rep.cgImage {
            return jpegData(from: cg, maxWidth: maxWidth)
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private func jpegData(from image: CGImage, maxWidth: CGFloat) -> Data? {
        let origW = CGFloat(image.width)
        let origH = CGFloat(image.height)
        let scale = min(1.0, maxWidth / max(1, origW))
        let targetW = max(1, Int(origW * scale))
        let targetH = max(1, Int(origH * scale))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private func captureWindow(id windowID: CGWindowID, maxWidth: CGFloat) -> Data? {
        guard windowID != 0 else { return nil }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_tile_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-l", "\(windowID)", tmpURL.path]
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        guard let src = CGImageSourceCreateWithURL(tmpURL as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        return jpegData(from: cg, maxWidth: maxWidth)
    }

    // MARK: - Default tile HTML

    private static func tileDefaultHTML(agentID: UUID) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body { margin:0; background:#0d0d0d; color:#e0e0e0;
                 font-family:-apple-system,sans-serif;
                 display:flex; align-items:center; justify-content:center;
                 height:100vh; flex-direction:column; gap:12px; }
          .label { font-size:22px; font-weight:600; }
          .sub   { font-size:14px; color:#666; }
        </style>
        </head>
        <body>
          <div class="label">Lumi Agent Tile</div>
          <div class="sub">\(agentID.uuidString.prefix(8))</div>
          <div class="sub">Navigate to a URL to begin</div>
        </body>
        </html>
        """
    }
}

#endif
