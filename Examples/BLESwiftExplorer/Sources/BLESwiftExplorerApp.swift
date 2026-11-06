//
//  BLESwiftExplorerApp.swift
//  BLESwiftExplorer
//
//  A SwiftUI sample app (iOS and macOS) that uses the full public surface of BLESwift: scanning,
//  filtering, connecting, GATT browsing, reads and writes (single and chunked), notifications, RSSI
//  polling, connection logging, reconnect of saved devices, system connection events, ANCS, and
//  background restoration. It depends on the local package by path and is not part of the SPM
//  package.
//

import BLESwiftProfiles
import Foundation
import SwiftUI

@main
struct BLESwiftExplorerApp: App {

    // Created synchronously in the App initializer, so `Central` exists before CoreBluetooth can
    // deliver a background-restoration callback. See the launch-time discipline in
    // `BackgroundRestoration.md`. The `ExplorerModel` initializer builds the `Central` and starts
    // to consume `restorationEvents()` immediately, in this same launch path.
    @State private var model = ExplorerModel()

    // The peripheral-role counterpart. Its `PeripheralHost` resolves a backend from
    // `BackendRegistry` at construction. It gets the link's backend because `AdvertiserModel`
    // creates the host lazily on the first `start()`, long after `ExplorerModel.init()` has
    // installed the link. The order of the declarations here does not make this safe, because
    // SwiftUI does not guarantee an order between two `@State` initial values.
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

    /// Launch arguments that the end-to-end test uses to drive the app without UI taps.
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
