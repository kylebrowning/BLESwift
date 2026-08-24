//
//  SavedDevicesView.swift
//  BLESwiftExplorer
//
//  Screen 5: saved-device list persisted in UserDefaults, reconnecting via
//  `central.connect(identifier:fallbackScan:reconnect:)` (Task 4) with a fallback
//  `ScanFilter`.
//

import BLESwift
import BLESwiftProfiles
import SwiftUI

struct SavedDevicesView: View {
    @Environment(ExplorerModel.self) private var model
    @State private var status: String?
    @State private var connected: ConnectedTarget?

    var body: some View {
        List {
            Section {
                Text("Saved peripheral UUIDs are remembered after a successful connect. Reconnect looks up the known peripheral first, then falls back to a filtered scan for the Heart Rate service.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved (\(model.savedDeviceIDs.count))") {
                if model.savedDeviceIDs.isEmpty {
                    Text("None saved yet — connect from the Scan tab.").foregroundStyle(.secondary)
                }
                ForEach(model.savedDeviceIDs, id: \.self) { uuid in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(uuid.uuidString).font(.callout)
                        HStack {
                            Button("Reconnect") { reconnect(uuid) }
                                .buttonStyle(.bordered)
                            Button("Forget", role: .destructive) { model.removeSavedDevice(uuid) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if let status {
                Section { Text(status).font(.caption) }
            }
        }
        .navigationTitle("Saved Devices")
        .navigationDestination(item: $connected) { target in
            PeripheralDetailView(peripheral: target.peripheral, title: target.name)
        }
    }

    private func reconnect(_ uuid: UUID) {
        status = "Reconnecting \(uuid)…"
        Task {
            // Fallback: if the system no longer knows the UUID, scan for a Heart Rate device.
            let fallback = ScanFilter(services: [HeartRateMeasurement.service])
            if let peripheral = await model.reconnectSaved(uuid, fallback: fallback) {
                status = "Reconnected."
                connected = ConnectedTarget(peripheral: peripheral, name: uuid.uuidString)
            } else {
                status = "Reconnect failed (see log)."
            }
        }
    }
}
