//
//  SystemEventsView.swift
//  BLESwiftExplorer
//
//  Screen 6: system-level connection events. `connectionEventRegistration` +
//  `SystemConnectionEvent` are iOS/tvOS/watchOS only (Task 7); macOS shows a note. ANCS
//  status is surfaced on the peripheral detail screen (iOS only).
//

import BLESwift
import BLESwiftProfiles
import SwiftUI

struct SystemEventsView: View {
    @Environment(ExplorerModel.self) private var model

    var body: some View {
        List {
            #if os(macOS)
            Section {
                Label("System connection-event registration is not available on macOS (CoreBluetooth's registerForConnectionEvents is unavailable there). ANCS is also iOS-only.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            #else
            Section {
                Text("Registered for system connection events on the Heart Rate service. Events arrive when any peripheral advertising it connects to or disconnects from the system.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System events (\(model.systemEventLog.count))") {
                if model.systemEventLog.isEmpty {
                    Text("No system connection events yet.").foregroundStyle(.secondary)
                }
                ForEach(model.systemEventLog.reversed()) { entry in
                    Text(entry.text).font(.callout)
                }
            }
            #endif
        }
        .navigationTitle("System Events")
        #if !os(macOS)
        .task {
            await model.consumeSystemConnectionEvents(services: [HeartRateMeasurement.service])
        }
        #endif
    }
}
