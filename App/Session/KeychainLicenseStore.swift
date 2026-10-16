// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if os(macOS)
    import Security

    protocol LicenseKeychainClient {
        func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
        func add(_ query: [String: Any]) -> OSStatus
        func delete(_ query: [String: Any]) -> OSStatus
    }

    struct SecurityLicenseKeychain: LicenseKeychainClient {
        func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        }

        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }

        func add(_ query: [String: Any]) -> OSStatus {
            SecItemAdd(query as CFDictionary, nil)
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            SecItemDelete(query as CFDictionary)
        }
    }

    public final class KeychainLicenseStore: LicenseStoring {
        private let service: String
        private let accessGroup: String?
        private let client: any LicenseKeychainClient
        private let migratesOnSave: Bool

        public init(service: String = "me.peapod.umbilical.license") {
            self.init(
                service: service,
                accessGroup: SignedLicenseAccessGroup.current(),
                client: SecurityLicenseKeychain(),
                migratesOnInit: true,
                migratesOnSave: true
            )
        }

        init(
            service: String,
            accessGroup: String?,
            client: any LicenseKeychainClient,
            migratesOnInit: Bool,
            migratesOnSave: Bool
        ) {
            self.service = service
            self.accessGroup = accessGroup.flatMap {
                LicenseKeychainAccessGroup.onlyAppGroup(in: [$0])
            }
            self.client = client
            self.migratesOnSave = migratesOnSave
            if migratesOnInit {
                migrateLegacyLoginItems()
            }
        }

        public func loadLabel() -> String? {
            guard let data = read(account: LicenseKeychainAccount.label) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public func saveLabel(_ label: String) -> Bool {
            guard let data = label.data(using: .utf8) else { return false }
            return store(account: LicenseKeychainAccount.label, data: data)
        }

        public func loadCredential() -> LicenseCredential? {
            guard let data = read(account: LicenseKeychainAccount.credential) else { return nil }
            return LicenseJSON.decode(LicenseCredential.self, from: data)
        }

        public func saveCredential(_ credential: LicenseCredential) -> Bool {
            guard let data = LicenseJSON.encode(credential) else { return false }
            return store(account: LicenseKeychainAccount.credential, data: data)
        }

        public func loadValidation() -> LicenseValidationRecord? {
            guard let data = read(account: LicenseKeychainAccount.validation) else { return nil }
            return LicenseJSON.decode(LicenseValidationRecord.self, from: data)
        }

        public func saveValidation(_ record: LicenseValidationRecord) -> Bool {
            guard let data = LicenseJSON.encode(record) else { return false }
            return store(account: LicenseKeychainAccount.validation, data: data)
        }

        public func clearCredential() {
            delete(account: LicenseKeychainAccount.credential)
        }

        public func clearValidation() {
            delete(account: LicenseKeychainAccount.validation)
        }

        func migrateLegacyLoginItems() {
            guard accessGroup != nil else { return }
            for account in LicenseKeychainAccount.all {
                switch load(account: account, legacy: true) {
                case .unavailable:
                    continue
                case .missing:
                    _ = deleteLegacy(account: account)
                case .value(let data):
                    switch load(account: account, legacy: false) {
                    case .value:
                        _ = deleteLegacy(account: account)
                    case .missing:
                        _ = write(account: account, data: data)
                    case .unavailable:
                        continue
                    }
                }
            }
        }

        static func dictionary(
            for query: LicenseKeychainQuery,
            data: Data? = nil
        ) -> [String: Any]? {
            if data != nil && !LicenseKeychainWriteGuard.canStore(query) {
                return nil
            }
            var result: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: query.service,
                kSecAttrAccount as String: query.account,
                kSecUseDataProtectionKeychain as String: query.useDataProtectionKeychain
            ]
            if let accessGroup = query.accessGroup {
                result[kSecAttrAccessGroup as String] = accessGroup
            }
            if query.matchAnySynchronizable {
                result[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            } else if let synchronizable = query.synchronizable {
                result[kSecAttrSynchronizable as String] = synchronizable
            }
            if let accessible = query.accessible {
                result[kSecAttrAccessible as String] = secAccessible(accessible)
            }
            if query.returnsData {
                result[kSecReturnData as String] = true
                result[kSecMatchLimit as String] = kSecMatchLimitOne
            }
            if let data {
                result[kSecValueData as String] = data
            }
            return result
        }

        static func replacementAttributes(data: Data) -> [String: Any] {
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: secAccessible(LicenseKeychainPolicy.item.accessible)
            ]
        }

        private func store(account: String, data: Data) -> Bool {
            if migratesOnSave {
                migrateLegacyLoginItems()
            }
            return write(account: account, data: data)
        }

        private func write(account: String, data: Data) -> Bool {
            guard let accessGroup else { return false }
            let lookup = LicenseKeychainQueries.dataProtection(
                service: service,
                account: account,
                accessGroup: accessGroup,
                storing: false
            )
            let addQuery = LicenseKeychainQueries.dataProtection(
                service: service,
                account: account,
                accessGroup: accessGroup,
                storing: true
            )
            guard LicenseKeychainWriteGuard.targetsDataProtection(lookup),
                LicenseKeychainWriteGuard.canStore(addQuery),
                let lookupDictionary = Self.dictionary(for: lookup),
                let addDictionary = Self.dictionary(for: addQuery, data: data)
            else { return false }
            let updated = client.update(lookupDictionary, Self.replacementAttributes(data: data))
            if updated == errSecSuccess {
                return deleteLegacy(account: account)
            }
            if updated != errSecItemNotFound {
                return false
            }
            guard client.add(addDictionary) == errSecSuccess else { return false }
            return deleteLegacy(account: account)
        }

        private func read(account: String) -> Data? {
            if case .value(let data) = load(account: account, legacy: false) {
                return data
            }
            return nil
        }

        private func delete(account: String) {
            if let accessGroup {
                let query = LicenseKeychainQueries.dataProtection(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    storing: false
                )
                if LicenseKeychainWriteGuard.targetsDataProtection(query),
                    let dictionary = Self.dictionary(for: query)
                {
                    _ = client.delete(dictionary)
                }
            }
            _ = deleteLegacy(account: account)
        }

        private func deleteLegacy(account: String) -> Bool {
            let query = LicenseKeychainQueries.legacyLoginDelete(service: service, account: account)
            guard LicenseKeychainWriteGuard.targetsLegacyLogin(query),
                let dictionary = Self.dictionary(for: query)
            else { return false }
            let status = client.delete(dictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        private func load(account: String, legacy: Bool) -> LoadResult {
            let query: LicenseKeychainQuery
            if legacy {
                query = LicenseKeychainQueries.legacyLoginDelete(
                    service: service,
                    account: account
                )
                guard LicenseKeychainWriteGuard.targetsLegacyLogin(query) else {
                    return .unavailable
                }
            } else {
                guard let accessGroup else { return .unavailable }
                query = LicenseKeychainQueries.dataProtection(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    storing: false
                )
                guard LicenseKeychainWriteGuard.targetsDataProtection(query) else {
                    return .unavailable
                }
            }
            var reading = query
            reading.returnsData = true
            guard let dictionary = Self.dictionary(for: reading) else { return .unavailable }
            let (status, item) = client.copyMatching(dictionary)
            if status == errSecItemNotFound { return .missing }
            guard status == errSecSuccess, let data = item as? Data else { return .unavailable }
            return .value(data)
        }

        private static func secAccessible(_ access: LicenseKeychainAccessibility) -> CFString {
            switch access {
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }

        private enum LoadResult {
            case value(Data)
            case missing
            case unavailable
        }
    }

    enum SignedLicenseAccessGroup {
        static func current() -> String? {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
            var staticCode: SecStaticCode?
            let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
            guard staticStatus == errSecSuccess, let staticCode else { return nil }
            var information: CFDictionary?
            let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
            guard
                SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
                let information
            else { return nil }
            let values = information as NSDictionary
            let rawEntitlements = values[kSecCodeInfoEntitlements as String]
            guard let entitlements = rawEntitlements as? NSDictionary else { return nil }
            let rawGroups = entitlements["keychain-access-groups"]
            guard let listed = stringList(rawGroups) else { return nil }
            return LicenseKeychainAccessGroup.onlyAppGroup(in: listed)
        }

        private static func stringList(_ raw: Any?) -> [String]? {
            if let groups = raw as? [String] { return groups }
            guard let groups = raw as? NSArray else { return nil }
            let listed = groups.compactMap { $0 as? String }
            guard listed.count == groups.count else { return nil }
            return listed
        }
    }
#endif
