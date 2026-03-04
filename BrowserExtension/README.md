# Lumi Browser Workspace — Extension

A minimal Chrome/Chromium/Edge browser extension that opens the **Lumi Browser
Workspace panel** as a dedicated browser tab when you click the toolbar button.

## What it does

| | |
|---|---|
| **Toolbar button** | Opens `http://localhost:47287/panel` as a new tab (or focuses the existing one) |
| **Panel page** | Shows a live tile grid — one 4 000×4 000 screenshot per agent — with URL nav controls |
| **No page injection** | The extension never modifies any website you visit; it is purely a launcher |

## Canvas architecture

```
┌──────────────── 20 000 × 20 000 virtual canvas ───────────────────┐
│  slot 0        slot 1        slot 2        slot 3        slot 4   │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │
│ │ Agent A  │ │ Agent B  │ │ Agent C  │ │ (free)   │ │ (free)   │ │
│ │ 4000×4000│ │ 4000×4000│ │ 4000×4000│ │          │ │          │ │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘ │
│  slot 5        slot 6  …                                           │
│  …                                                                 │
└────────────────────────────────────────────────────────────────────┘
```

- The canvas is either a real `CGVirtualDisplay` (macOS 12.4+ with entitlement)
  or a set of off-screen WKWebView windows that mimic the same grid layout.
- Each tile is an independent `WKWebView`-backed `NSWindow`.
- Agents navigate, interact, and screenshot their own tile using the
  `assign_browser_tile`, `navigate_browser_tile`, and `capture_agent_screen`
  tools in Lumi.

## How to install (Chrome / Edge)

1. Build or run the Lumi app so `BrowserWorkspaceServer` starts on port 47287.
2. In Chrome, open `chrome://extensions` → enable **Developer mode**.
3. Click **Load unpacked** and select this `BrowserExtension/` folder.
4. The Lumi icon appears in the toolbar.  Click it to open the panel.

## How to use without the extension

Navigate directly to `http://localhost:47287/panel` in any browser while
Lumi is running.
