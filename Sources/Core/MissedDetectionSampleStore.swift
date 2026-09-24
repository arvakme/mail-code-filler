import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum MissedSampleStoreError: LocalizedError {
    case full
    case missingKey
    case damagedSample
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .full: return "样本已达 200 条。继续保存将删除最早的一条样本。"
        case .missingKey: return "样本密钥不存在，无法读取加密样本。"
        case .damagedSample: return "加密样本损坏，无法读取。"
        case .keychain: return "无法访问登录钥匙串，样本未以明文保存。"
        }
    }
}

public protocol MissedSampleKeyStore {
    func load(id: UUID) throws -> Data?
    func save(_ key: Data, id: UUID) throws
    func delete(id: UUID) throws
}

public struct KeychainMissedSampleKeys: MissedSampleKeyStore {
    private let service: String

    public init(service: String = "dev.zhijie.MailCodeFiller.samples") {
        self.service = service
    }

    public func load(id: UUID) throws -> Data? {
        var query = identity(id: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MissedSampleStoreError.keychain(status) }
        return item as? Data
    }

    public func save(_ key: Data, id: UUID) throws {
        var attributes = identity(id: id)
        attributes[kSecValueData] = key
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw MissedSampleStoreError.keychain(status) }
    }

    public func delete(id: UUID) throws {
        let status = SecItemDelete(identity(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MissedSampleStoreError.keychain(status)
        }
    }

    private func identity(id: UUID) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: context,
        ]
    }
}

/// Encrypted files contain only AES-GCM combined bytes and use random UUID filenames.
public struct MissedDetectionSampleStore {
    public static let capacity = 200
    public let directory: URL
    private let keys: any MissedSampleKeyStore
    private let fileManager: FileManager

    public init(
        directory: URL? = nil,
        keys: any MissedSampleKeyStore = KeychainMissedSampleKeys(),
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.keys = keys
        if let directory {
            self.directory = directory
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            self.directory = support.appending(path: "dev.zhijie.MailCodeFiller/samples")
        }
        try fileManager.createDirectory(
            at: self.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public func list() throws -> [MissedDetectionSample] {
        let files = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        return try files.map(read).sorted { $0.redactedAt > $1.redactedAt }
    }

    public func save(
        _ sample: MissedDetectionSample, reviewed: Bool,
        confirmEviction: Bool = false
    ) throws {
        try MissedSampleValidator.validate(sample, reviewed: reviewed)
        let existing = try list()
        guard existing.count < Self.capacity || confirmEviction else {
            throw MissedSampleStoreError.full
        }
        let key = SymmetricKey(size: .bits256)
        let rawKey = key.withUnsafeBytes { Data($0) }
        let plain = try JSONEncoder().encode(sample)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
            throw MissedSampleStoreError.damagedSample
        }
        let destination = file(for: sample.id)
        try keys.save(rawKey, id: sample.id)
        do {
            try sealed.write(to: destination, options: [.atomic])
        } catch {
            try? keys.delete(id: sample.id)
            throw error
        }
        if existing.count >= Self.capacity, let oldest = existing.last {
            do {
                try delete(id: oldest.id)
            } catch {
                try? fileManager.removeItem(at: destination)
                try? keys.delete(id: sample.id)
                throw error
            }
        }
    }

    public func read(id: UUID) throws -> MissedDetectionSample {
        try read(file(for: id))
    }

    public func delete(id: UUID) throws {
        try fileManager.removeItem(at: file(for: id))
        try keys.delete(id: id)
    }

    public func deleteAll() throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                throw MissedSampleStoreError.damagedSample
            }
            try delete(id: id)
        }
    }

    private func read(_ url: URL) throws -> MissedDetectionSample {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
            throw MissedSampleStoreError.damagedSample
        }
        guard let rawKey = try keys.load(id: id) else {
            throw MissedSampleStoreError.missingKey
        }
        let combined = try Data(contentsOf: url)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: rawKey))
            let sample = try JSONDecoder().decode(MissedDetectionSample.self, from: plain)
            guard sample.id == id else { throw MissedSampleStoreError.damagedSample }
            return sample
        } catch {
            throw MissedSampleStoreError.damagedSample
        }
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: id.uuidString).appendingPathExtension("json")
    }
}
