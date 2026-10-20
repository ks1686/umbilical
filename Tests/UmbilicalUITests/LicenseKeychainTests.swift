// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

#if os(macOS)
    import Security
#endif

#if os(macOS)
    final class LicenseKeychainAttributeTests: XCTestCase {
        private let group = "AB12CD34EF.me.peapod.umbilical"
        private let serviceName = "me.peapod.umbilical.license"

        func testItemsAreAfterFirstUnlockThisDeviceOnly() throws {
            let addQuery = LicenseKeychainQueries.dataProtection(
                service: serviceName,
                account: "validation",
                accessGroup: group,
                storing: true
            )
            let add = try XCTUnwrap(
                KeychainLicenseStore.dictionary(for: addQuery, data: Data("validation".utf8))
            )
            XCTAssertEqual(add[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(add[kSecAttrAccessGroup as String] as? String, group)
            XCTAssertEqual(
                add[kSecAttrAccessible as String] as? String,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
            let lookupQuery = LicenseKeychainQueries.dataProtection(
                service: serviceName,
                account: "validation",
                accessGroup: group,
                storing: false
            )
            let lookup = try XCTUnwrap(KeychainLicenseStore.dictionary(for: lookupQuery))
            XCTAssertEqual(lookup[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(lookup[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(lookup[kSecAttrAccessGroup as String] as? String, group)
            XCTAssertNil(lookup[kSecAttrAccessible as String])
            XCTAssertNil(lookup[kSecValueData as String])
            let legacyQuery = LicenseKeychainQueries.legacyLoginDelete(
                service: serviceName,
                account: "validation"
            )
            let legacy = try XCTUnwrap(KeychainLicenseStore.dictionary(for: legacyQuery))
            XCTAssertEqual(legacy[kSecUseDataProtectionKeychain as String] as? Bool, false)
            XCTAssertEqual(
                legacy[kSecAttrSynchronizable as String] as? String,
                kSecAttrSynchronizableAny as String
            )
            XCTAssertNil(legacy[kSecAttrAccessGroup as String])
            XCTAssertNil(legacy[kSecAttrAccessible as String])
            XCTAssertNil(legacy[kSecValueData as String])
            XCTAssertNil(
                KeychainLicenseStore.dictionary(for: legacyQuery, data: Data("secret".utf8))
            )
            let replacement = KeychainLicenseStore.replacementAttributes(data: Data("v".utf8))
            XCTAssertEqual(
                replacement[kSecAttrAccessible as String] as? String,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
            XCTAssertNil(replacement[kSecUseDataProtectionKeychain as String])
        }
    }

    final class LicenseKeychainFallbackTests: XCTestCase {
        private let group = "AB12CD34EF.me.peapod.umbilical"

        func testEachLicenseItemIsADataProtectionWrite() throws {
            let client = RecordingKeychain()
            client.updates = Array(repeating: errSecItemNotFound, count: 3)
            client.adds = Array(repeating: errSecSuccess, count: 3)
            let store = makeStore(client)
            XCTAssertTrue(store.saveLabel(LicenseFixture.label))
            XCTAssertTrue(store.saveCredential(LicenseFixture.credential()))
            XCTAssertTrue(
                store.saveValidation(
                    LicenseFixture.validation(validatedAt: Date(timeIntervalSince1970: 10))
                )
            )
            let adds = client.events.filter { $0.kind == .add }
            XCTAssertEqual(
                adds.map { $0.query[kSecAttrAccount as String] as? String },
                ["device-label", "credential", "validation"]
            )
            for event in client.events where event.kind == .add || event.kind == .update {
                XCTAssertEqual(event.query[kSecUseDataProtectionKeychain as String] as? Bool, true)
                XCTAssertEqual(event.query[kSecAttrSynchronizable as String] as? Bool, false)
                XCTAssertEqual(event.query[kSecAttrAccessGroup as String] as? String, group)
            }
            for add in adds {
                XCTAssertEqual(
                    add.query[kSecAttrAccessible as String] as? String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                )
            }
            let updates = client.events.filter { $0.kind == .update }
            XCTAssertEqual(updates.count, 3)
            for update in updates {
                XCTAssertEqual(
                    update.attributes[kSecAttrAccessible as String] as? String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                )
            }
            let deletes = client.events.filter { $0.kind == .delete }
            XCTAssertEqual(deletes.count, 3)
            for delete in deletes {
                let protection = delete.query[kSecUseDataProtectionKeychain as String] as? Bool
                XCTAssertEqual(protection, false)
                XCTAssertNil(delete.query[kSecValueData as String])
            }
        }

        func testDataProtectionFailureDoesNotFallBackToTheLoginKeychain() throws {
            let client = RecordingKeychain()
            client.updates = [errSecItemNotFound, errSecMissingEntitlement]
            client.adds = [errSecMissingEntitlement]
            let store = makeStore(client)
            XCTAssertFalse(store.saveCredential(LicenseFixture.credential()))
            XCTAssertFalse(
                store.saveValidation(
                    LicenseFixture.validation(validatedAt: Date(timeIntervalSince1970: 1))
                )
            )
            let writes = client.events.filter { $0.kind == .add || $0.kind == .update }
            XCTAssertFalse(writes.isEmpty)
            for event in writes {
                XCTAssertEqual(event.query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            }
            XCTAssertEqual(client.events.filter { $0.kind == .add }.count, 1)
            XCTAssertFalse(client.events.contains { $0.kind == .delete })
        }

        func testSaveFailsWhenTheAccessGroupIsNotTheAppGroup() {
            let client = RecordingKeychain()
            let store = KeychainLicenseStore(
                service: "me.peapod.umbilical.license",
                accessGroup: "me.peapod.umbilical",
                client: client,
                migratesOnInit: false,
                migratesOnSave: false
            )
            XCTAssertFalse(store.saveLabel(LicenseFixture.label))
            XCTAssertNil(store.loadCredential())
            XCTAssertTrue(client.events.isEmpty)
        }

        func testLoadReadsTheDataProtectionKeychainOnly() throws {
            let client = RecordingKeychain()
            let payload = try XCTUnwrap(LicenseJSON.encode(LicenseFixture.credential()))
            client.onCopy = { query in
                XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
                return (errSecSuccess, payload)
            }
            let store = makeStore(client)
            XCTAssertEqual(store.loadCredential(), LicenseFixture.credential())
            XCTAssertEqual(client.events.count, 1)
        }

        func testClearRemovesDataProtectionAndLoginCopies() {
            let client = RecordingKeychain()
            let store = makeStore(client)
            store.clearCredential()
            XCTAssertEqual(client.events.map(\.kind), [.delete, .delete])
            XCTAssertEqual(
                client.events[0].query[kSecUseDataProtectionKeychain as String] as? Bool,
                true
            )
            XCTAssertEqual(
                client.events[1].query[kSecUseDataProtectionKeychain as String] as? Bool,
                false
            )
            XCTAssertNil(client.events[1].query[kSecValueData as String])
        }

        func testMigrateCopiesLoginItemsThenDeletesThem() {
            let client = RecordingKeychain()
            let legacy = Data("legacy-credential".utf8)
            client.onCopy = { query in
                let account = query[kSecAttrAccount as String] as? String
                let protection = query[kSecUseDataProtectionKeychain as String] as? Bool
                if protection == false && account == "credential" {
                    return (errSecSuccess, legacy)
                }
                return (errSecItemNotFound, nil)
            }
            client.updates = [errSecItemNotFound]
            client.adds = [errSecSuccess]
            _ = makeStore(client, migratesOnInit: true)
            let adds = client.events.filter { $0.kind == .add }
            XCTAssertEqual(adds.count, 1)
            XCTAssertEqual(adds[0].query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(adds[0].query[kSecAttrAccount as String] as? String, "credential")
            XCTAssertEqual(adds[0].query[kSecValueData as String] as? Data, legacy)
            let credentialDeletes = client.events.filter {
                $0.kind == .delete
                    && ($0.query[kSecAttrAccount as String] as? String) == "credential"
                    && ($0.query[kSecUseDataProtectionKeychain as String] as? Bool) == false
            }
            XCTAssertEqual(credentialDeletes.count, 1)
        }

        func testMigrateLeavesTheLoginItemWhenDataProtectionWriteFails() {
            let client = RecordingKeychain()
            client.onCopy = { query in
                let account = query[kSecAttrAccount as String] as? String
                let protection = query[kSecUseDataProtectionKeychain as String] as? Bool
                if protection == false && account == "credential" {
                    return (errSecSuccess, Data("legacy-credential".utf8))
                }
                return (errSecItemNotFound, nil)
            }
            client.updates = [errSecItemNotFound]
            client.adds = [errSecMissingEntitlement]
            _ = makeStore(client, migratesOnInit: true)
            let adds = client.events.filter { $0.kind == .add }
            XCTAssertEqual(adds.count, 1)
            XCTAssertEqual(adds[0].query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            let credentialDeletes = client.events.filter { event in
                let account = event.query[kSecAttrAccount as String] as? String
                return event.kind == .delete && account == "credential"
            }
            XCTAssertTrue(credentialDeletes.isEmpty)
        }

        func testMigrateDeletesTheLoginCopyWhenDataProtectionAlreadyHasTheItem() {
            let client = RecordingKeychain()
            client.onCopy = { query in
                let account = query[kSecAttrAccount as String] as? String
                guard account == "credential" else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, Data("stored".utf8))
            }
            _ = makeStore(client, migratesOnInit: true)
            XCTAssertTrue(client.events.filter { $0.kind == .add }.isEmpty)
            XCTAssertTrue(client.events.filter { $0.kind == .update }.isEmpty)
            let credentialDeletes = client.events.filter {
                $0.kind == .delete
                    && ($0.query[kSecAttrAccount as String] as? String) == "credential"
                    && ($0.query[kSecUseDataProtectionKeychain as String] as? Bool) == false
            }
            XCTAssertEqual(credentialDeletes.count, 1)
        }

        private func makeStore(
            _ client: RecordingKeychain,
            migratesOnInit: Bool = false
        ) -> KeychainLicenseStore {
            KeychainLicenseStore(
                service: "me.peapod.umbilical.license",
                accessGroup: group,
                client: client,
                migratesOnInit: migratesOnInit,
                migratesOnSave: false
            )
        }
    }

    private final class RecordingKeychain: LicenseKeychainClient {
        enum Kind: Equatable {
            case copy
            case update
            case add
            case delete
        }

        struct Event {
            var kind: Kind
            var query: [String: Any]
            var attributes: [String: Any]
        }

        var events: [Event] = []
        var updates: [OSStatus] = []
        var adds: [OSStatus] = []
        var onCopy: (([String: Any]) -> (OSStatus, Data?))?

        func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            events.append(Event(kind: .copy, query: query, attributes: [:]))
            let result = onCopy?(query) ?? (errSecItemNotFound, nil)
            return (result.0, result.1 as CFTypeRef?)
        }

        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
            events.append(Event(kind: .update, query: query, attributes: attributes))
            if updates.isEmpty { return errSecUnimplemented }
            return updates.removeFirst()
        }

        func add(_ query: [String: Any]) -> OSStatus {
            events.append(Event(kind: .add, query: query, attributes: [:]))
            if adds.isEmpty { return errSecUnimplemented }
            return adds.removeFirst()
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            events.append(Event(kind: .delete, query: query, attributes: [:]))
            return errSecSuccess
        }
    }
#endif
