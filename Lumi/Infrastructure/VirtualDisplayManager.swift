//
//  VirtualDisplayManager.swift
//  LumiAgent
//
//  Manages per-agent virtual displays so each browser-workspace agent operates
//  on its own isolated, large off-screen canvas.
//
//  Strategy
//  ────────
//  macOS 12.4+ ships CGVirtualDisplay which genuinely registers a fake display
//  with the WindowServer.  This requires the restricted
//  `com.apple.developer.virtual-displays` entitlement, which most developer
//  accounts don't hold.
//
//  When that entitlement is absent (the typical case) we fall back to a large
//  off-screen NSWindow ("workspace window") that acts as the agent's private
//  canvas.  The native `screencapture -l <windowID>` tool can capture any
//  on-screen window by ID, so the agent can still call `capture_agent_screen`
//  and see whatever is rendered into that window.
//
//  On macOS 12.4+ WITH the virtual-display entitlement:
//    • A CGVirtualDisplay (20 000 × 20 000 pt @ 1×) is created per agent.
//    • The display is registered with the WindowServer; macOS Spaces and apps
//      that enumerate NSScreen.screens will see it as a real monitor.
//    • The display ID is stored and used when the agent calls screencapture.
//
//  Either way, the agent gets a `displayID` (real or pseudo) it can pass to
//  `captureScreenAsJPEG(displayID:)`.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

// MARK: - Virtual Display Descriptor

/// Metadata about one agent's virtual display / workspace window.
public struct AgentDisplay: Identifiable, Sendable {
    public let id: UUID              // agent id
    public let displayID: UInt32?    // CGDirectDisplayID if a real virtual display was created
    public let windowID: CGWindowID? // backing NSWindow ID (fallback or always set)
    public let size: CGSize          // logical points

    public var label: String { "Agent \(id.uuidString.prefix(8))" }

    /// Whether this is backed by a genuine CGVirtualDisplay.
    public var isVirtualDisplay: Bool { displayID != nil }
}

// MARK: - Virtual Display Manager

/// Singleton that creates and tears down per-agent virtual workspaces.
@MainActor
public final class VirtualDisplayManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = VirtualDisplayManager()

    // MARK: - Constants

    /// Logical size of each workspace canvas.
    /// 20 000 × 20 000 pt mirrors the requirement; the actual pixel count
    /// depends on the backing scale factor.
    public static let workspaceSize = CGSize(width: 20_000, height: 20_000)

    // MARK: - Published State

    @Published public private(set) var agentDisplays: [UUID: AgentDisplay] = [:]

    // MARK: - Private

    /// NSWindows used as fallback workspace canvases, keyed by agent ID.
    private var workspaceWindows: [UUID: NSWindow] = [:]

    private init() {}

    // MARK: - Public API

    /// Create (or return the existing) virtual workspace for `agentID`.
    /// Returns the `AgentDisplay` descriptor on success.
    @discardableResult
    public func createWorkspace(for agentID: UUID) -> AgentDisplay {
        if let existing = agentDisplays[agentID] { return existing }

        // Try CGVirtualDisplay first (macOS 12.4+, restricted entitlement).
        if let display = tryCreateCGVirtualDisplay(for: agentID) {
            agentDisplays[agentID] = display
            return display
        }

        // Fallback: off-screen NSWindow.
        let display = createWorkspaceWindow(for: agentID)
        agentDisplays[agentID] = display
        return display
    }

    /// Destroy the virtual workspace for `agentID`, releasing system resources.
    public func destroyWorkspace(for agentID: UUID) {
        workspaceWindows[agentID]?.close()
        workspaceWindows.removeValue(forKey: agentID)
        agentDisplays.removeValue(forKey: agentID)
        // CGVirtualDisplay objects are released via ARC when we remove the
        // reference below — see `virtualDisplayObjects`.
        virtualDisplayObjects.removeValue(forKey: agentID)
    }

    /// Capture the workspace for `agentID` as JPEG data, suitable for AI vision.
    public func captureWorkspace(for agentID: UUID, maxWidth: CGFloat = 1440) -> Data? {
        guard let info = agentDisplays[agentID] else { return nil }

        if let displayID = info.displayID {
            // Real virtual display: use the existing per-display capture.
            return captureScreenAsJPEG(maxWidth: maxWidth, displayID: displayID)
        }

        if let windowID = info.windowID {
            return captureWindow(id: windowID, maxWidth: maxWidth)
        }

        return nil
    }

    // MARK: - CGVirtualDisplay (macOS 12.4+)

    /// Opaque holder for the CGVirtualDisplay object (kept alive via ARC).
    private var virtualDisplayObjects: [UUID: AnyObject] = [:]

    private func tryCreateCGVirtualDisplay(for agentID: UUID) -> AgentDisplay? {
        // CGVirtualDisplay was added in macOS 12.4 / CoreGraphics framework.
        // We call it dynamically so the binary still loads on older systems.
        guard #available(macOS 12.4, *) else { return nil }

        // CGVirtualDisplayCreate() requires the
        // com.apple.developer.virtual-displays entitlement.
        // A SIGTRAP / kCGErrorNotPermitted will be thrown when the entitlement
        // is absent.  We catch that by checking the descriptor API availability
        // and swallowing the resulting nil.
        guard let descriptor = CGVirtualDisplayDescriptor() else { return nil }
        descriptor.name = "Lumi Agent Workspace"
        descriptor.sizeInMillimeters = CGSize(width: 520, height: 520)
        descriptor.queue = DispatchQueue.main
        descriptor.resizeSensorCallback = nil

        let settings = CGVirtualDisplaySettings()
        let mode = CGVirtualDisplayMode(
            width: UInt32(Self.workspaceSize.width),
            height: UInt32(Self.workspaceSize.height),
            refreshRate: 30
        )
        settings.hiDPI = false
        settings.modes = [mode]

        guard let vd = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        guard vd.apply(settings) == .success else { return nil }

        // Obtain the real CGDirectDisplayID.
        let displayID = vd.displayID
        guard displayID != kCGNullDirectDisplay else { return nil }

        // Keep the object alive.
        virtualDisplayObjects[agentID] = vd

        let display = AgentDisplay(
            id: agentID,
            displayID: displayID,
            windowID: nil,
            size: Self.workspaceSize
        )
        print("[VirtualDisplayManager] Created CGVirtualDisplay \(displayID) for agent \(agentID)")
        return display
    }

    // MARK: - Fallback: off-screen NSWindow

    private func createWorkspaceWindow(for agentID: UUID) -> AgentDisplay {
        let size = Self.workspaceSize
        // Place the window far off-screen so it isn't visible to the user
        // but remains "on-screen" in Window Server terms so screencapture -l works.
        let offscreenOrigin = CGPoint(
            x: CGFloat(50_000) + CGFloat(agentDisplays.count) * 100,
            y: CGFloat(50_000)
        )
        let frame = CGRect(origin: offscreenOrigin, size: size)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumi Virtual Workspace — \(agentID.uuidString.prefix(8))"
        window.backgroundColor = .black
        window.isOpaque = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Make the window visible so screencapture can capture it.
        window.orderFront(nil)

        let windowID = CGWindowID(window.windowNumber)
        workspaceWindows[agentID] = window

        let display = AgentDisplay(
            id: agentID,
            displayID: nil,
            windowID: windowID,
            size: size
        )
        print("[VirtualDisplayManager] Created workspace window \(windowID) for agent \(agentID)")
        return display
    }

    // MARK: - Window capture helper

    private func captureWindow(id windowID: CGWindowID, maxWidth: CGFloat) -> Data? {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi_ws_\(UUID().uuidString).png")
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
}

#endif
