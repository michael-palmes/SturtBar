// Signposts.swift — os_signpost instrumentation for the app's hot paths.
//
// Categories (inspect in Instruments → os_signpost, subsystem com.michaelpalmes.sturtbar):
//   "launch"     — process main() → applicationDidFinishLaunching complete
//   "refresh"    — each usage refresh (UsageStore.performRefresh)
//   "scan"       — each cost scan (CostScanner)
//   "iconRender" — each menu bar icon raster (IconRenderer cache misses)
//   "menu"       — status-item menu open → close (StatusItemController+Menu)

import Foundation
import os

enum Signposts {
    private static let subsystem = "com.michaelpalmes.sturtbar"

    static let launch = OSSignposter(subsystem: subsystem, category: "launch")
    static let refresh = OSSignposter(subsystem: subsystem, category: "refresh")
    static let scan = OSSignposter(subsystem: subsystem, category: "scan")
    static let iconRender = OSSignposter(subsystem: subsystem, category: "iconRender")
    static let menu = OSSignposter(subsystem: subsystem, category: "menu")
}
