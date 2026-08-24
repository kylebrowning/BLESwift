//
//  BLESwiftExplorerApp.swift
//  BLESwiftExplorer
//
//  A SwiftUI sample app (iOS + macOS) that exercises the full BLESwift public surface —
//  scanning, filtering, connecting, GATT browsing, reads/writes (single and chunked),
//  notifications, RSSI polling, connection logging, saved-device reconnect, system
//  connection events, ANCS, and background restoration. It depends on the local package
//  by path; it is not part of the SPM package.
//

import SwiftUI

@main
struct BLESwiftExplorerApp: App {

    // Created synchronously in the App initializer so `Central` exists before CoreBluetooth
    // can deliver a background-restoration callback — see `BackgroundRestoration.md`'s
    // launch-time discipline. `ExplorerModel`'s initializer builds the `Central` and starts
    // consuming `restorationEvents()` immediately, in this same launch path.
    @State private var model = ExplorerModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
