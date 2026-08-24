//
//  RestorationDemoView.swift
//  BLESwiftExplorer
//
//  Screen 7: background state restoration demo (iOS). `Central` is built with a
//  `RestorationConfiguration` in the App initializer, and `restorationEvents()` is consumed
//  from the same launch path (see `ExplorerModel.init`), per `BackgroundRestoration.md`.
//  macOS shows a note that restoration is iOS-only.
//

import SwiftUI

struct RestorationDemoView: View {
    @Environment(ExplorerModel.self) private var model

    var body: some View {
        List {
            #if os(iOS)
            Section {
                Text("This app enables CoreBluetooth background state restoration with a stable identifier, constructed synchronously at launch. Restoration events replay everything buffered since Central.init. To see events, connect to a peripheral, background the app, and let iOS relaunch it for a Bluetooth event.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Restoration events (\(model.restorationLog.count))") {
                if model.restorationLog.isEmpty {
                    Text("No restoration events yet (none expected without a real background relaunch).")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.restorationLog.reversed()) { entry in
                    Text(entry.text).font(.callout)
                }
            }
            #else
            Section {
                Label("Background state restoration is an iOS-only CoreBluetooth feature; there is nothing to restore on macOS.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .navigationTitle("Restoration")
    }
}
