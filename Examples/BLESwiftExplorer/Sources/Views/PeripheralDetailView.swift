//
//  PeripheralDetailView.swift
//  BLESwiftExplorer
//
//  Screen 3: the GATT browser and per-characteristic operations —
//  discoverServices/Characteristics/Descriptors, properties(of:), read (hex + typed
//  profile decode, Task 6), single write, chunked write with a live progress bar (Task 3),
//  notify toggle with a `survivesReconnect` switch (Task 2) and live values, RSSI polling,
//  `readDeviceInformation`/`readBatteryLevel` (Task 6), and ANCS status (Task 7, iOS).
//

import BLESwift
import BLESwiftProfiles
import Foundation
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class PeripheralDetailModel {
    let peripheral: Peripheral

    struct CharacteristicRow: Identifiable {
        let id: CharacteristicIdentifier
        var properties: CharacteristicProperties = []
        var descriptors: [DescriptorIdentifier] = []
        var lastValue: String?
        var notifyValues: [String] = []
        var isNotifying = false
        var survivesReconnect = false
        var chunkProgress: Double?
        var writeHex = ""
    }

    struct ServiceRow: Identifiable {
        let id: ServiceIdentifier
        var characteristics: [CharacteristicRow] = []
    }

    var services: [ServiceRow] = []
    var status = "Not discovered"
    var rssi: Int?
    var deviceInfo: String?
    var batteryLevel: String?
    var ancsAuthorized: Bool?

    private var notifyTasks: [CharacteristicIdentifier: Task<Void, Never>] = [:]
    private var rssiTask: Task<Void, Never>?

    init(peripheral: Peripheral) {
        self.peripheral = peripheral
    }

    // MARK: Discovery

    func discover() async {
        do {
            status = "Discovering services…"
            let serviceIDs = try await peripheral.discoverServices()
            var rows: [ServiceRow] = []
            for service in serviceIDs {
                var row = ServiceRow(id: service)
                let chars = try await peripheral.discoverCharacteristics(for: service)
                for char in chars {
                    var cRow = CharacteristicRow(id: char)
                    cRow.properties = (try? await peripheral.properties(of: char)) ?? []
                    cRow.descriptors = (try? await peripheral.discoverDescriptors(for: char)) ?? []
                    row.characteristics.append(cRow)
                }
                rows.append(row)
            }
            services = rows
            status = "\(serviceIDs.count) service(s)"
        } catch {
            status = "Discovery failed: \(error)"
        }
    }

    // MARK: Read / write

    func read(_ char: CharacteristicIdentifier) async {
        do {
            // Raw read as `Data`, then a typed profile decode when the UUID is known.
            let data: Data = try await peripheral.read(from: char)
            update(char) { $0.lastValue = CharacteristicDecoder.decode(data, for: char) }
        } catch {
            update(char) { $0.lastValue = "read failed: \(error)" }
        }
    }

    func write(_ char: CharacteristicIdentifier, hex: String) async {
        guard let data = Self.parseHex(hex) else {
            update(char) { $0.lastValue = "invalid hex" }
            return
        }
        do {
            try await peripheral.write(data, to: char)
            update(char) { $0.lastValue = "wrote \(data.count) bytes" }
        } catch {
            update(char) { $0.lastValue = "write failed: \(error)" }
        }
    }

    /// Chunked write via the `AsyncThrowingStream<WriteProgress, Error>` overload (Task 3),
    /// driving a live progress bar.
    func writeChunkedStreamed(_ char: CharacteristicIdentifier, hex: String) async {
        guard let data = Self.parseHex(hex), !data.isEmpty else {
            update(char) { $0.lastValue = "invalid/empty hex" }
            return
        }
        update(char) { $0.chunkProgress = 0 }
        do {
            let stream: AsyncThrowingStream<WriteProgress, Error> =
                peripheral.writeChunked(data, to: char, type: .withResponse, chunkSize: 20)
            for try await progress in stream {
                let fraction = progress.totalBytes == 0 ? 1 : Double(progress.bytesSent) / Double(progress.totalBytes)
                update(char) { $0.chunkProgress = fraction }
            }
            update(char) { $0.lastValue = "chunked wrote \(data.count) bytes"; $0.chunkProgress = nil }
        } catch {
            update(char) { $0.lastValue = "chunked write failed: \(error)"; $0.chunkProgress = nil }
        }
    }

    /// Chunked write via the plain `async throws` overload (Task 3) — no progress stream.
    func writeChunkedAwaited(_ char: CharacteristicIdentifier, hex: String) async {
        guard let data = Self.parseHex(hex), !data.isEmpty else {
            update(char) { $0.lastValue = "invalid/empty hex" }
            return
        }
        do {
            try await peripheral.writeChunked(data, to: char, type: .withResponse, chunkSize: 20)
            update(char) { $0.lastValue = "chunked (awaited) wrote \(data.count) bytes" }
        } catch {
            update(char) { $0.lastValue = "chunked write failed: \(error)" }
        }
    }

    // MARK: Notifications (Task 2)

    func toggleNotify(_ char: CharacteristicIdentifier, survivesReconnect: Bool) {
        if let existing = notifyTasks[char] {
            existing.cancel()
            notifyTasks[char] = nil
            update(char) { $0.isNotifying = false }
            return
        }
        update(char) { $0.isNotifying = true; $0.notifyValues = [] }
        notifyTasks[char] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream: AsyncThrowingStream<Data, Error> = peripheral.notifications(
                    for: char,
                    policy: .bufferingNewest(10),
                    survivesReconnect: survivesReconnect
                )
                for try await data in stream {
                    let decoded = CharacteristicDecoder.decode(data, for: char)
                    update(char) {
                        $0.notifyValues.insert(decoded, at: 0)
                        if $0.notifyValues.count > 20 { $0.notifyValues.removeLast() }
                    }
                }
            } catch {
                update(char) { $0.notifyValues.insert("notify ended: \(error)", at: 0) }
            }
            update(char) { $0.isNotifying = false }
        }
    }

    // MARK: RSSI polling

    func startRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let value = try? await peripheral.readRSSI() {
                    rssi = value
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = nil
    }

    // MARK: Profiles (Task 6)

    func loadDeviceInformation() async {
        do {
            let info = try await peripheral.readDeviceInformation()
            deviceInfo = "\(info.manufacturerName ?? "?") / \(info.modelNumber ?? "?") / fw \(info.firmwareRevision ?? "?")"
        } catch {
            deviceInfo = "DIS read failed: \(error)"
        }
    }

    func loadBatteryLevel() async {
        do {
            let level = try await peripheral.readBatteryLevel()
            batteryLevel = "\(level)%"
        } catch {
            batteryLevel = "battery read failed: \(error)"
        }
    }

    // MARK: ANCS (Task 7, iOS)

    #if os(iOS)
    func refreshANCS() async {
        ancsAuthorized = await peripheral.ancsAuthorized
    }

    func observeANCS() async {
        for await authorized in peripheral.ancsAuthorizationEvents() {
            ancsAuthorized = authorized
        }
    }
    #endif

    // MARK: Teardown

    func tearDown() {
        stopRSSIPolling()
        for task in notifyTasks.values { task.cancel() }
        notifyTasks.removeAll()
        Task { [peripheral] in try? await peripheral.disconnect() }
    }

    // MARK: Helpers

    private func update(_ char: CharacteristicIdentifier, _ mutate: (inout CharacteristicRow) -> Void) {
        for s in services.indices {
            if let c = services[s].characteristics.firstIndex(where: { $0.id == char }) {
                mutate(&services[s].characteristics[c])
                return
            }
        }
    }

    static func parseHex(_ string: String) -> Data? {
        let cleaned = string.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func describe(_ properties: CharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

// MARK: - View

struct PeripheralDetailView: View {
    @Environment(ExplorerModel.self) private var appModel
    @State private var model: PeripheralDetailModel
    let title: String

    init(peripheral: Peripheral, title: String) {
        _model = State(initialValue: PeripheralDetailModel(peripheral: peripheral))
        self.title = title
    }

    var body: some View {
        List {
            headerSection
            profilesSection
            ForEach(model.services) { service in
                serviceSection(service)
            }
        }
        .navigationTitle(title)
        .task { await model.discover() }
        .task { model.startRSSIPolling() }
        #if os(iOS)
        .task { await model.refreshANCS() }
        .task { await model.observeANCS() }
        #endif
        .onDisappear { model.tearDown() }
    }

    private var headerSection: some View {
        Section("Peripheral") {
            LabeledContent("Status", value: model.status)
            LabeledContent("RSSI", value: model.rssi.map { "\($0) dBm" } ?? "—")
            #if os(iOS)
            LabeledContent("ANCS authorized", value: model.ancsAuthorized.map { $0 ? "yes" : "no" } ?? "—")
            #endif
        }
    }

    private var profilesSection: some View {
        Section("Profiles (Task 6)") {
            Button("Read Device Information") { Task { await model.loadDeviceInformation() } }
            if let deviceInfo = model.deviceInfo {
                Text(deviceInfo).font(.caption).foregroundStyle(.secondary)
            }
            Button("Read Battery Level") { Task { await model.loadBatteryLevel() } }
            if let batteryLevel = model.batteryLevel {
                Text(batteryLevel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func serviceSection(_ service: PeripheralDetailModel.ServiceRow) -> some View {
        Section("Service \(service.id.uuidString)") {
            ForEach(service.characteristics) { char in
                characteristicRow(char)
            }
        }
    }

    @ViewBuilder
    private func characteristicRow(_ char: PeripheralDetailModel.CharacteristicRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(char.id.uuidString).font(.headline)
            Text("properties: \(PeripheralDetailModel.describe(char.properties))")
                .font(.caption).foregroundStyle(.secondary)
            if !char.descriptors.isEmpty {
                Text("descriptors: \(char.descriptors.map(\.uuidString).joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if CharacteristicDecoder.isKnown(char.id) {
                Text("known profile characteristic").font(.caption2).foregroundStyle(.blue)
            }
            if let value = char.lastValue {
                Text("value: \(value)").font(.caption).textSelection(.enabled)
            }

            HStack {
                Button("Read") { Task { await model.read(char.id) } }
                    .buttonStyle(.bordered)
                Button(char.isNotifying ? "Stop notify" : "Notify") {
                    model.toggleNotify(char.id, survivesReconnect: char.survivesReconnect)
                }
                .buttonStyle(.bordered)
            }

            Toggle("survivesReconnect (Task 2)", isOn: bindingSurvives(char.id))
                .font(.caption)

            HStack {
                TextField("write hex (e.g. 01FF)", text: bindingWriteHex(char.id))
                    .textFieldStyle(.roundedBorder)
                Button("Write") { Task { await model.write(char.id, hex: writeHex(char.id)) } }
                    .buttonStyle(.bordered)
            }
            HStack {
                Button("Chunked (progress)") { Task { await model.writeChunkedStreamed(char.id, hex: writeHex(char.id)) } }
                    .buttonStyle(.bordered)
                Button("Chunked (await)") { Task { await model.writeChunkedAwaited(char.id, hex: writeHex(char.id)) } }
                    .buttonStyle(.bordered)
            }
            if let progress = char.chunkProgress {
                ProgressView(value: progress)
            }

            if !char.notifyValues.isEmpty {
                ForEach(Array(char.notifyValues.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // Bindings that reach into the model's row array by identifier.

    private func rowIndex(_ char: CharacteristicIdentifier) -> (Int, Int)? {
        for s in model.services.indices {
            if let c = model.services[s].characteristics.firstIndex(where: { $0.id == char }) {
                return (s, c)
            }
        }
        return nil
    }

    private func bindingSurvives(_ char: CharacteristicIdentifier) -> Binding<Bool> {
        Binding(
            get: { rowIndex(char).map { model.services[$0.0].characteristics[$0.1].survivesReconnect } ?? false },
            set: { newValue in if let (s, c) = rowIndex(char) { model.services[s].characteristics[c].survivesReconnect = newValue } }
        )
    }

    private func bindingWriteHex(_ char: CharacteristicIdentifier) -> Binding<String> {
        Binding(
            get: { rowIndex(char).map { model.services[$0.0].characteristics[$0.1].writeHex } ?? "" },
            set: { newValue in if let (s, c) = rowIndex(char) { model.services[s].characteristics[c].writeHex = newValue } }
        )
    }

    private func writeHex(_ char: CharacteristicIdentifier) -> String {
        rowIndex(char).map { model.services[$0.0].characteristics[$0.1].writeHex } ?? ""
    }
}
