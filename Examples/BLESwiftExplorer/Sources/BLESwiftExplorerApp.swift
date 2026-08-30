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

import BLESwiftProfiles
import Foundation
import SwiftUI

@main
struct BLESwiftExplorerApp: App {

    // Created synchronously in the App initializer so `Central` exists before CoreBluetooth
    // can deliver a background-restoration callback — see `BackgroundRestoration.md`'s
    // launch-time discipline. `ExplorerModel`'s initializer builds the `Central` and starts
    // consuming `restorationEvents()` immediately, in this same launch path.
    @State private var model = ExplorerModel()

    // The peripheral-role counterpart. Its `PeripheralHost` resolves a backend from
    // `BackendRegistry` at construction, and gets the link's because `AdvertiserModel`
    // creates it lazily on the first `start()` — long after `ExplorerModel.init()` has
    // installed the link. Declaration order here is not what makes that safe: SwiftUI
    // guarantees no ordering between two `@State` initial values.
    @State private var advertiser = AdvertiserModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(advertiser)
                .task {
                    applyLaunchArguments()
                    await model.start()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }

    /// Launch arguments used by the end-to-end test to drive the app without UI taps.
    @MainActor
    private func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--auto-advertise") {
            advertiser.start()
        }
        if arguments.contains("--auto-scan") {
            model.startServiceScan(services: [HeartRateMeasurement.service])
        }
    }
}
