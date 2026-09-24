import Foundation
import Testing

@testable import MailCodeCore

private final class MemorySampleKeys: MissedSampleKeyStore {
    var values: [UUID: Data] = [:]

    func load(id: UUID) throws -> Data? { values[id] }
    func save(_ key: Data, id: UUID) throws { values[id] = key }
    func delete(id: UUID) throws { values[id] = nil }
}

@Suite("Encrypted missed sample storage")
struct MissedDetectionSampleStoreTests {
    private func fixture(_ date: Date = Date()) -> MissedDetectionSample {
        MissedDetectionSample(
            subject: "验证码", fromDomain: "example.test", mime: "text/plain",
            body: .text("验证码：000000"), expected: .init(codes: ["000000"]),
            redactedAt: date)
    }

    @Test func encryptedRoundTripTamperAndMissingKey() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MemorySampleKeys()
        let store = try MissedDetectionSampleStore(directory: directory, keys: keys)
        let sample = fixture()
        try store.save(sample, reviewed: true)
        let file = directory.appending(path: sample.id.uuidString + ".json")
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.contains(Data("验证码".utf8)))
        #expect(try store.read(id: sample.id) == sample)
        keys.values[sample.id] = nil
        #expect(throws: MissedSampleStoreError.self) { try store.read(id: sample.id) }
        keys.values[sample.id] = Data(repeating: 0, count: 32)
        #expect(throws: MissedSampleStoreError.self) { try store.read(id: sample.id) }
    }

    @Test func capacityNeedsExplicitEvictionConsent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MissedDetectionSampleStore(directory: directory, keys: MemorySampleKeys())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<200 {
            try store.save(fixture(start.addingTimeInterval(Double(index))), reviewed: true)
        }
        let extra = fixture(start.addingTimeInterval(500))
        #expect(throws: MissedSampleStoreError.self) {
            try store.save(extra, reviewed: true)
        }
        #expect(try store.list().count == 200)
        try store.save(extra, reviewed: true, confirmEviction: true)
        #expect(try store.list().count == 200)
        #expect(try store.list().contains { $0.id == extra.id })
        try store.deleteAll()
        #expect(try store.list().isEmpty)
    }
}
