//
//  AdvertiseView.swift
//  BLESwiftExplorer
//
//  The peripheral-role screen: advertise a Heart Rate service, watch the simulated BPM
//  cycle, and see every write a remote central sends.
//

#if os(iOS) || os(macOS)

import SwiftUI

struct AdvertiseView: View {
    @Environment(AdvertiserModel.self) private var model

    private var advertising: Binding<Bool> {
        Binding(
            get: { model.isAdvertising },
            set: { $0 ? model.start() : model.stop() }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle("Advertise as BLESwift Explorer Sim", isOn: advertising)
                    .accessibilityIdentifier("advertise.toggle")
                Text(model.isAdvertising ? "Advertising" : "Not advertising")
                    .accessibilityIdentifier("advertise.status")
                Text("\(model.bpm) bpm")
                    .accessibilityIdentifier("advertise.bpm")
                Text(model.stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Writes received (\(model.log.count))") {
                ForEach(model.log) { entry in
                    Text(entry.text).font(.caption).monospaced()
                }
            }
        }
        .navigationTitle("Advertise")
    }
}

#endif
