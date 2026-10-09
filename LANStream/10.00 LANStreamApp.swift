// MARK: - LANStreamApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Application entry point.
//
// The SwiftUI App scene is intentionally empty: LAN Stream has no primary window,
// and every piece of user-facing surface (the status item and the settings window)
// is created by AppDelegate. Settings { EmptyView() } declares a scene without
// materializing one, which is what keeps SwiftUI from opening a window at launch.

import SwiftUI

@main
struct LANStreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
