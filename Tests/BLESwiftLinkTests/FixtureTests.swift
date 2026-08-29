//
//  FixtureTests.swift
//  BLESwiftLinkTests
//

import BLESwiftCore
import BLESwiftLink
import Foundation
import Testing

@Suite("Fixtures")
struct FixtureTests {

    static let json = """
    {
      "devices": [
        {
          "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
          "name": "Fixture HRM",
          "advertisedServices": ["180D"],
          "manufacturerData": "AQI=",
          "services": [
            {
              "uuid": "180D",
              "characteristics": [
                { "uuid": "2A37", "properties": ["read", "notify"], "value": "AEg=" },
                { "uuid": "2A39", "properties": ["write"], "permissions": ["writeable", "writeEncryptionRequired"] }
              ]
            },
            { "uuid": "180F", "isPrimary": false, "characteristics": [] }
          ]
        }
      ]
    }
    """

    @Test("Parses a document and derives Core types")
    func parse() throws {
        let document = try FixtureDocument.parse(Data(Self.json.utf8))
        #expect(document.devices.count == 1)
        let device = document.devices[0]
        #expect(device.name == "Fixture HRM")
        #expect(device.manufacturerData == Data([1, 2]))

        let advertisement = device.advertisement
        #expect(advertisement.localName == "Fixture HRM")
        #expect(advertisement.serviceUUIDs == [ServiceIdentifier(uuid: "180D")])
        #expect(advertisement.isConnectable == true)

        let services = device.gattServices
        #expect(services.count == 2)
        #expect(services[0].isPrimary == true)
        #expect(services[1].isPrimary == false)
        let hrm = services[0].characteristics[0]
        #expect(hrm.properties == [.read, .notify])
        #expect(hrm.permissions == [.readable])            // derived
        #expect(hrm.value == Data([0, 0x48]))
        let control = services[0].characteristics[1]
        #expect(control.properties == [.write])
        #expect(control.permissions == [.writeable, .writeEncryptionRequired])
        #expect(control.value == nil)
    }

    @Test("Unknown property strings fail decoding")
    func unknownProperty() {
        let bad = Self.json.replacingOccurrences(of: "\"notify\"", with: "\"telepathy\"")
        #expect(throws: (any Error).self) { try FixtureDocument.parse(Data(bad.utf8)) }
    }

    @Test("Round-trips through Codable")
    func roundTrip() throws {
        let document = try FixtureDocument.parse(Data(Self.json.utf8))
        let data = try JSONEncoder().encode(document)
        #expect(try FixtureDocument.parse(data) == document)
    }

    @Test("Loads from a file URL")
    func load() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID()).json")
        try Data(Self.json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FixtureDocument.load(from: url).devices.count == 1)
    }

    /// A malformed UUID anywhere in a fixture used to trap the provider at load, inside the
    /// identifier it was handed to. Each one is now a `DecodingError` naming its key, which
    /// `bleswift-provider` prints before exiting 66.
    @Test(
        "A malformed UUID fails decoding rather than trapping",
        arguments: [
            ("\"advertisedServices\": [\"180D\"]", "\"advertisedServices\": [\"zzzz\"]", "advertisedServices"),
            ("{ \"uuid\": \"180F\", \"isPrimary\": false", "{ \"uuid\": \"zzzz\", \"isPrimary\": false", "uuid"),
            ("{ \"uuid\": \"2A37\"", "{ \"uuid\": \"zzzz\"", "uuid"),
        ]
    )
    func malformedUUIDFailsDecoding(original: String, replacement: String, key: String) throws {
        let bad = Self.json.replacingOccurrences(of: original, with: replacement)
        #expect(bad != Self.json)
        let error = #expect(throws: DecodingError.self) {
            try FixtureDocument.parse(Data(bad.utf8))
        }
        guard case .dataCorrupted(let context) = try #require(error) else {
            Issue.record("expected a dataCorrupted error, got \(String(describing: error))")
            return
        }
        // The message names both the offending string and where in the document it sits.
        #expect(context.codingPath.last?.stringValue == key)
        #expect(context.codingPath.first?.stringValue == "devices")
        #expect(context.debugDescription.contains("zzzz"))
    }
}
