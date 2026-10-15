// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if os(macOS)
    import Security

    public final class KeychainLicenseStore: LicenseStoring {
        private let service: String

        public init(service: String = "me.peapod.umbilical.license") {
            self.service = service
        }

        public func loadLabel() -> String? {
            guard let data = read(account: Account.label) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public func saveLabel(_ label: String) -> Bool {
            guard let data = label.data(using: .utf8) else { return false }
            return write(account: Account.label, data: data)
        }

        public func loadCredential() -> LicenseCredential? {
            guard let data = read(account: Account.credential) else { return nil }
            return LicenseJSON.decode(LicenseCredential.self, from: data)
        }

        public func saveCredential(_ credential: LicenseCredential) -> Bool {
            guard let data = LicenseJSON.encode(credential) else { return false }
            return write(account: Account.credential, data: data)
        }

        public func loadValidation() -> LicenseValidationRecord? {
            guard let data = read(account: Account.validation) else { return nil }
            return LicenseJSON.decode(LicenseValidationRecord.self, from: data)
        }

        public func saveValidation(_ record: LicenseValidationRecord) -> Bool {
            guard let data = LicenseJSON.encode(record) else { return false }
            return write(account: Account.validation, data: data)
        }

        public func clearCredential() {
            delete(account: Account.credential)
        }

        public func clearValidation() {
            delete(account: Account.validation)
        }

        static func lookupAttributes(service: String, account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: LicenseKeychainPolicy.item.synchronizable
            ]
        }

        static func addAttributes(service: String, account: String, data: Data) -> [String: Any] {
            var query = lookupAttributes(service: service, account: account)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = secAccessible(
                LicenseKeychainPolicy.item.accessible)
            return query
        }

        private func write(account: String, data: Data) -> Bool {
            let lookup = Self.lookupAttributes(service: service, account: account)
            let status = SecItemUpdate(
                lookup as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            let add = Self.addAttributes(service: service, account: account, data: data)
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }

        private func read(account: String) -> Data? {
            var query = Self.lookupAttributes(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess else { return nil }
            return item as? Data
        }

        private func delete(account: String) {
            let query = Self.lookupAttributes(service: service, account: account)
            SecItemDelete(query as CFDictionary)
        }

        private static func secAccessible(_ access: LicenseKeychainAccessibility) -> CFString {
            switch access {
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }

        private enum Account {
            static let label = "device-label"
            static let credential = "credential"
            static let validation = "validation"
        }
    }
#endif
