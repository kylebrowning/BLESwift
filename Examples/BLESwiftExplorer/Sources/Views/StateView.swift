//
//  StateView.swift
//  BLESwiftExplorer
//
//  Screen 1: Bluetooth state & authorization — the "power on" gate, driven by
//  `central.stateEvents()` and `central.authorization`.
//

import BLESwift
import SwiftUI

struct StateView: View {
    @Environment(ExplorerModel.self) private var model

    var body: some View {
        List {
            Section("Radio") {
                LabeledContent("State", value: describe(model.centralState))
                LabeledContent("Authorization", value: describe(model.authorization))
                LabeledContent("Scanning", value: model.isScanning ? "yes" : "no")
            }
            Section {
                if model.centralState == .poweredOn {
                    Label("Bluetooth is ready — scanning is enabled.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Label("Waiting for Bluetooth to power on…", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("State")
    }

    private func describe(_ state: CentralState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "powered off"
        case .poweredOn: return "powered on"
        @unknown default: return "—"
        }
    }

    private func describe(_ auth: BluetoothAuthorization) -> String {
        switch auth {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowed"
        @unknown default: return "—"
        }
    }
}
