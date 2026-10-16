// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum LicenseKeychainAccessibility: String, Equatable {
    case afterFirstUnlockThisDeviceOnly
}

/// Every license Keychain item uses this policy.
public struct LicenseKeychainPolicy: Equatable {
    public var accessible: LicenseKeychainAccessibility
    public var synchronizable: Bool
    public var useDataProtectionKeychain: Bool

    public static let item = LicenseKeychainPolicy(
        accessible: .afterFirstUnlockThisDeviceOnly,
        synchronizable: false,
        useDataProtectionKeychain: true
    )
}

public struct LicenseCredential: Codable, Equatable {
    public var key: String
    public var activationID: String
    public var deviceID: String
    public var block: LicenseServerBlock?
}

/// Last successful Polar check. The key, activation id, and device id must
/// all match this Mac before the timestamp can grant offline use.
public struct LicenseValidationRecord: Codable, Equatable {
    public var key: String
    public var activationID: String
    public var deviceID: String
    public var validatedAt: Date
    public var observedAt: Date
}

public enum LicenseServerBlock: String, Codable, Equatable {
    case revoked
    case disabled
    case expired
    case notFound
    case rejected

    var denial: LicenseDenial {
        switch self {
        case .revoked:
            return .revoked
        case .disabled:
            return .disabled
        case .expired:
            return .expired
        case .notFound:
            return .notFound
        case .rejected:
            return .rejected
        }
    }
}

public protocol LicenseStoring: AnyObject {
    func loadLabel() -> String?
    func saveLabel(_ label: String) -> Bool
    func loadCredential() -> LicenseCredential?
    func saveCredential(_ credential: LicenseCredential) -> Bool
    func loadValidation() -> LicenseValidationRecord?
    func saveValidation(_ record: LicenseValidationRecord) -> Bool
    func clearCredential()
    func clearValidation()
}

final class MemoryLicenseStore: LicenseStoring {
    var label: String?
    var credential: LicenseCredential?
    var validation: LicenseValidationRecord?
    var failLabelSave = false
    var failCredentialSave = false
    var failValidationSave = false

    func loadLabel() -> String? { label }

    func saveLabel(_ label: String) -> Bool {
        if failLabelSave { return false }
        self.label = label
        return true
    }

    func loadCredential() -> LicenseCredential? { credential }

    func saveCredential(_ credential: LicenseCredential) -> Bool {
        if failCredentialSave { return false }
        self.credential = credential
        return true
    }

    func loadValidation() -> LicenseValidationRecord? { validation }

    func saveValidation(_ record: LicenseValidationRecord) -> Bool {
        if failValidationSave { return false }
        validation = record
        return true
    }

    func clearCredential() { credential = nil }

    func clearValidation() { validation = nil }
}

enum LicenseJSON {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

public enum LicenseDeviceLabel {
    public static func make(uuid: UUID = UUID()) -> String {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "umbilical-\(hex.prefix(8))"
    }
}

enum LicenseKeyNormalize {
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        guard trimmed.allSatisfy({ !$0.isWhitespace }) else { return nil }
        return trimmed
    }
}

enum LicenseKeyMask {
    static func mask(_ key: String) -> String {
        guard key.count >= 8 else { return "saved key" }
        return "ending \(key.suffix(4))"
    }
}
