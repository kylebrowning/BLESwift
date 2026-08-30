//
//  ScanView.swift
//  BLESwiftExplorer
//
//  Screen 2: scan list with `ScanFilter` controls (Task 4), a `GATTCompatibility` picker
//  (Task 5), an ANCS toggle (Task 7, iOS), a `findFirst` action, and tap-to-connect that
//  pushes the peripheral detail browser.
//

import BLESwift
import BLESwiftProfiles
import SwiftUI

struct ScanView: View {
    @Environment(ExplorerModel.self) private var model

    // ScanFilter inputs.
    @State private var namePrefix = ""
    @State private var manufacturerID = ""
    @State private var servicesText = ""
    @State private var minimumRSSI: Double = -100
    @State private var connectableOnly = false
    @State private var allowDuplicates = false

    // Connect options.
    @State private var compatibility: CompatibilityChoice = .strict
    @State private var requiresANCS = false

    @State private var findFirstResult: String?
    @State private var connecting = false
    @State private var connected: ConnectedTarget?

    var body: some View {
        List {
            filterSection
            connectSection
            actionsSection
            resultsSection
        }
        .navigationTitle("Scan")
        .navigationDestination(item: $connected) { target in
            PeripheralDetailView(peripheral: target.peripheral, title: target.name)
        }
    }

    private var filterSection: some View {
        Section("ScanFilter (Task 4)") {
            TextField("Name prefix", text: $namePrefix)
            TextField("Manufacturer ID (decimal)", text: $manufacturerID)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField("Service UUIDs (comma-separated, e.g. 180D,180F)", text: $servicesText)
            VStack(alignment: .leading) {
                Text("Minimum RSSI: \(Int(minimumRSSI)) dBm")
                Slider(value: $minimumRSSI, in: -100 ... 0)
            }
            Toggle("Connectable only", isOn: $connectableOnly)
            Toggle("Allow duplicates", isOn: $allowDuplicates)
        }
    }

    private var connectSection: some View {
        Section("Connect options") {
            Picker("GATT compatibility (Task 5)", selection: $compatibility) {
                Text("Strict").tag(CompatibilityChoice.strict)
                Text("Lenient").tag(CompatibilityChoice.lenient)
                Text("Custom (read w/o prop)").tag(CompatibilityChoice.customLenientRead)
            }
            #if os(iOS)
            Toggle("Require ANCS (Task 7)", isOn: $requiresANCS)
            #endif
        }
    }

    private var actionsSection: some View {
        Section {
            if model.isScanning {
                Button("Stop scan", role: .destructive) { model.stopScan() }
            } else {
                Button("Start filtered scan") {
                    model.startScan(filter: buildFilter(), allowDuplicates: allowDuplicates, rssiThreshold: nil)
                }
                Button("Scan Heart Rate service (baseline scan(services:))") {
                    model.startServiceScan(services: [HeartRateMeasurement.service])
                }
                .accessibilityIdentifier("scan.startHeartRate")
            }
            Button("findFirst(matching:) →") {
                Task { findFirstResult = await model.findFirst(matching: buildFilter()) }
            }
            if let findFirstResult {
                Text(findFirstResult).font(.caption).foregroundStyle(.secondary)
            }
            if let scanError = model.scanError {
                Text(scanError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var resultsSection: some View {
        Section("Discoveries (\(model.discoveries.count))") {
            ForEach(model.discoveries) { item in
                Button {
                    connect(item)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name).font(.headline)
                            .accessibilityIdentifier("scan.resultName")
                        Text("\(item.rssi) dBm · \(item.discovery.peripheral.uuid.uuidString)")
                            .font(.caption).foregroundStyle(.secondary)
                        if !item.services.isEmpty {
                            Text("services: \(item.services.map(\.uuidString).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("scan.result.\(item.name)")
            }
        }
    }

    private func connect(_ item: DiscoveredPeripheral) {
        guard !connecting else { return }
        connecting = true
        Task {
            if let peripheral = await model.connect(
                item.discovery,
                compatibility: compatibility.value,
                requiresANCS: requiresANCS
            ) {
                connected = ConnectedTarget(peripheral: peripheral, name: item.name)
            }
            connecting = false
        }
    }

    /// Assembles a `ScanFilter` from the UI, exercising every field.
    private func buildFilter() -> ScanFilter {
        let services = servicesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ServiceIdentifier(uuid: $0) }

        return ScanFilter(
            services: services.isEmpty ? nil : services,
            namePrefix: namePrefix.isEmpty ? nil : namePrefix,
            manufacturerID: UInt16(manufacturerID),
            minimumRSSI: minimumRSSI <= -100 ? nil : Int(minimumRSSI),
            connectableOnly: connectableOnly,
            custom: { _ in true } // escape-hatch predicate (accepts everything here)
        )
    }
}

/// A connected peripheral plus a display name, for `navigationDestination(item:)`.
struct ConnectedTarget: Identifiable, Hashable {
    let id = UUID()
    let peripheral: Peripheral
    let name: String

    static func == (lhs: ConnectedTarget, rhs: ConnectedTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
