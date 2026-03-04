//
//  VirtualDisplayManager.swift
//  LumiAgent
//
//  Single shared 20 000 × 20 000 virtual canvas, tiled into 4 000 × 4 000
//  agent slots.  Each agent's slot is backed by a WKWebView NSWindow placed
//  at the tile's origin so the agent can browse, interact, and screenshot its
//  own tile independently.
//
//  Canvas layout (tiles per row = 5, rows = 5, max 25 concurrent agents)
//  ────────────────────────────────────────────────────────────────────────
//  slot 0  : origin (    0,     0)   slot 1  : origin ( 4000,     0) …
//  slot 5  : origin (    0,  4000)   slot 6  : origin ( 4000,  4000) …
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

// MARK: - Agent Tile

/// All the information about one agent's 4 000 × 4 000 tile on the canvas.
public struct AgentTile: Identifiable, Sendable {
    public let id: UUID           // agent ID
    public let slot: Int          // 0-based grid slot
    public let tileOrigin: CGPoint // origin within the 20 000 × 20 000 canvas
    public let windowID: CGWindowID
    public var currentURL: String?
}

// MARK: - Virtual Display Manager

/// Singleton that owns the shared virtual canvas and all per-agent browser tiles.
@MainActor
public final class VirtualDisplayManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = VirtualDisplayManager()

    // MARK: - Canvas constants

    /// Total size of the shared virtual canvas.
    public static let canvasSize  = CGSize(width: 20_000, height: 20_000)
    /// Size of each agent's browser tile.
    public static let tileSize    = CGSize(width: 4_000,  height: 4_000)
    /// Number of tiles in each row (canvasSize.width / tileSize.width).
    public static let tilesPerRow = 5

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
    /// Opens a 4 000 × 4 000 WKWebView window at the tile origin.
    /// - Parameter url: Optional starting URL to load in the browser tile.
    @discardableResult
    public func assignTile(to agentID: UUID, url: String? = nil) -> AgentTile? {
        if let existing = tiles[agentID] { return existing }

        guard let slot = nextFreeSlot() else {
            print("[VirtualDisplayManager] All \(Self.tilesPerRow * Self.tilesPerRow) slots occupied")
            return nil
        }

        let origin = tileOrigin(for: slot)
        let window = createBrowserWindow(at: origin, agentID: agentID, url: url)
        let wid = CGWindowID(window.windowNumber)

        let tile = AgentTile(
            id: agentID,
            slot: slot,
            tileOrigin: origin,
            windowID: wid,
            currentURL: url
        )
        tiles[agentID] = tile
        occupiedSlots[slot] = agentID
        browserWindows[agentID] = window
        print("[VirtualDisplayManager] Agent \(agentID) → slot \(slot) origin \(origin) window \(wid)")
        return tile
    }

    /// Navigate the agent's browser tile to a new URL.
    public func navigate(agentID: UUID, to urlString: String) {
        guard let url = URL(string: urlString),
              let window = browserWindows[agentID],
              let webView = window.contentView as? WKWebView else { return }
        webView.load(URLRequest(url: url))
        // Struct value type: extract, mutate, reassign.
        if var tile = tiles[agentID] {
            tile.currentURL = urlString
            tiles[agentID] = tile
        }
    }

    /// Release an agent's tile, closing its browser window.
    public func releaseTile(for agentID: UUID) {
        if let tile = tiles[agentID] {
            occupiedSlots.removeValue(forKey: tile.slot)
        }
        browserWindows[agentID]?.close()
        browserWindows.removeValue(forKey: agentID)
        tiles.removeValue(forKey: agentID)
    }

    // MARK: - Capture

    /// Capture the agent's 4 000 × 4 000 browser window as JPEG data.
    /// `maxWidth` controls the output resolution; defaults to 1 440 px wide.
    public func captureAgentTile(agentID: UUID, maxWidth: CGFloat = 1440) -> Data? {
        guard let tile = tiles[agentID] else { return nil }
        return captureWindow(id: tile.windowID, maxWidth: maxWidth)
    }

    // MARK: - Private: CGVirtualDisplay

    private func tryCreateCGVirtualDisplay() -> UInt32? {
        guard #available(macOS 12.4, *) else { return nil }

        guard let descriptor = CGVirtualDisplayDescriptor() else { return nil }
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
        guard vd.apply(settings) == .success else { return nil }
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

    // MARK: - Private: tile geometry

    /// Returns the tile origin (within the 20 000 × 20 000 canvas) for `slot`.
    private func tileOrigin(for slot: Int) -> CGPoint {
        let col = slot % Self.tilesPerRow
        let row = slot / Self.tilesPerRow
        return CGPoint(
            x: CGFloat(col) * Self.tileSize.width,
            y: CGFloat(row) * Self.tileSize.height
        )
    }

    /// Returns the next unoccupied slot index, or nil if all 25 are taken.
    private func nextFreeSlot() -> Int? {
        let maxSlots = Self.tilesPerRow * Self.tilesPerRow
        return (0 ..< maxSlots).first { occupiedSlots[$0] == nil }
    }

    /// Off-screen coordinate used as the canvas origin in fallback mode.
    /// Large enough that no physical display will ever reach it.
    private var canvasOffscreenOffset: CGFloat { 50_000 }

    // MARK: - Private: window capture

    private func captureWindow(id windowID: CGWindowID, maxWidth: CGFloat) -> Data? {
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

        let origW = CGFloat(cg.width), origH = CGFloat(cg.height)
        let scale = min(1.0, maxWidth / max(1, origW))
        let tw = max(1, Int(origW * scale))
        let th = max(1, Int(origH * scale))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }

        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
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
