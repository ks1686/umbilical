// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

#if os(macOS)
    import Security
#endif

final class LicenseRuleTests: XCTestCase {
    func testBindingRejectsAnotherDeviceOrAnotherKey() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validation = LicenseFixture.validation(validatedAt: now)
        let credential = LicenseFixture.credential()
        XCTAssertTrue(
            LicenseBinding.accepts(
                validation: validation,
                credential: credential,
                deviceID: LicenseFixture.deviceID
            )
        )
        XCTAssertFalse(
            LicenseBinding.accepts(
                validation: validation,
                credential: credential,
                deviceID: LicenseFixture.otherDeviceID
            )
        )
        let otherKey = LicenseFixture.credential(key: LicenseFixture.otherKey)
        XCTAssertFalse(
            LicenseBinding.accepts(
                validation: validation,
                credential: otherKey,
                deviceID: LicenseFixture.deviceID
            )
        )
    }

    func testValidationRecordJSONIncludesKeyActivationAndDevice() throws {
        let record = LicenseFixture.validation(validatedAt: Date(timeIntervalSince1970: 10))
        let data = try XCTUnwrap(LicenseJSON.encode(record))
        let json = try licenseJSON(data)
        XCTAssertEqual(json["key"] as? String, record.key)
        XCTAssertEqual(json["activationID"] as? String, record.activationID)
        XCTAssertEqual(json["deviceID"] as? String, record.deviceID)
    }

    func testLicenseNeverStopsActiveDownloads() {
        let summary = LicenseSummary(
            maskedKey: "ending 0001",
            deviceLabel: LicenseFixture.label,
            validatedAt: Date(timeIntervalSince1970: 10)
        )
        let until = Date(timeIntervalSince1970: 20)
        let statuses: [LicenseStatus] = [
            .unofficial(LicenseCopy.unofficialDebug),
            .licensed(summary),
            .offlineGrace(summary, until: until),
            .unlicensed(.missing),
            .unlicensed(.unvalidated),
            .unlicensed(.limitReached),
            .unlicensed(.revoked),
            .unlicensed(.graceExpired),
            .unlicensed(.clockRollback)
        ]
        for status in statuses {
            XCTAssertFalse(LicensePermissions.resolve(status).stopsActiveDownloads)
        }
    }

    func testKeychainPolicyIsThisDeviceOnly() {
        XCTAssertEqual(
            LicenseKeychainPolicy.item.accessible,
            .afterFirstUnlockThisDeviceOnly
        )
        XCTAssertFalse(LicenseKeychainPolicy.item.synchronizable)
        XCTAssertTrue(LicenseKeychainPolicy.item.useDataProtectionKeychain)
    }

    func testAccessGroupIsOnlyTheAppTeamAndBundleID() {
        let group = "AB12CD34EF.me.peapod.umbilical"
        XCTAssertEqual(LicenseKeychainAccessGroup.onlyAppGroup(in: [group]), group)
        XCTAssertNil(LicenseKeychainAccessGroup.onlyAppGroup(in: []))
        XCTAssertNil(
            LicenseKeychainAccessGroup.onlyAppGroup(in: [group, "AB12CD34EF.me.peapod.other"])
        )
        XCTAssertNil(LicenseKeychainAccessGroup.onlyAppGroup(in: ["me.peapod.umbilical"]))
        XCTAssertNil(
            LicenseKeychainAccessGroup.onlyAppGroup(
                in: ["$(AppIdentifierPrefix)me.peapod.umbilical"]
            )
        )
        XCTAssertNil(LicenseKeychainAccessGroup.onlyAppGroup(in: ["AB12CD34EF.*"]))
        XCTAssertNil(
            LicenseKeychainAccessGroup.onlyAppGroup(in: ["AB12CD34EF.me.peapod.umbilical.extra"])
        )
        XCTAssertNil(
            LicenseKeychainAccessGroup.onlyAppGroup(in: ["ab12cd34ef.me.peapod.umbilical"])
        )
    }

    func testDataProtectionQueriesDoNotTargetTheLoginKeychain() {
        let group = "AB12CD34EF.me.peapod.umbilical"
        for account in LicenseKeychainAccount.all {
            let stored = LicenseKeychainQueries.dataProtection(
                service: "me.peapod.umbilical.license",
                account: account,
                accessGroup: group,
                storing: true
            )
            XCTAssertTrue(LicenseKeychainWriteGuard.canStore(stored), account)
            XCTAssertTrue(stored.useDataProtectionKeychain, account)
            XCTAssertEqual(stored.synchronizable, Optional(false), account)
            XCTAssertEqual(stored.accessible, .afterFirstUnlockThisDeviceOnly, account)
            XCTAssertEqual(stored.accessGroup, group, account)
            var loginWrite = stored
            loginWrite.useDataProtectionKeychain = false
            XCTAssertFalse(LicenseKeychainWriteGuard.canStore(loginWrite), account)
            var synced = stored
            synced.synchronizable = true
            XCTAssertFalse(LicenseKeychainWriteGuard.canStore(synced), account)
            let legacy = LicenseKeychainQueries.legacyLoginDelete(
                service: "me.peapod.umbilical.license",
                account: account
            )
            XCTAssertFalse(LicenseKeychainWriteGuard.canStore(legacy), account)
            XCTAssertTrue(LicenseKeychainWriteGuard.targetsLegacyLogin(legacy), account)
            XCTAssertFalse(legacy.useDataProtectionKeychain, account)
            XCTAssertNil(legacy.accessible, account)
            XCTAssertNil(legacy.accessGroup, account)
        }
    }

    func testKeychainAccessGroupStaysOnTheAppEntitlements() throws {
        let app = try entitlementsPlist("App/umbilical.entitlements")
        XCTAssertEqual(
            app["keychain-access-groups"] as? [String],
            ["$(AppIdentifierPrefix)me.peapod.umbilical"]
        )
        for relative in [
            "App/umbilical-debug.entitlements",
            "Extension/Extension.entitlements",
            "helpers/yt-dlp.entitlements"
        ] {
            let other = try entitlementsPlist(relative)
            XCTAssertNil(other["keychain-access-groups"], relative)
        }
    }

    func testSHA256MatchesKnownVectors() {
        XCTAssertEqual(
            SHA256Hex.digest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256Hex.digest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let hashed = SHA256Hex.digest("IOPlatformUUID-sample")
        XCTAssertEqual(hashed.count, 64)
        XCTAssertFalse(hashed.contains("IOPlatformUUID"))
        XCTAssertNotEqual(
            SHA256Hex.digest("mac-a"),
            SHA256Hex.digest("mac-b")
        )
    }

    func testDeviceLabelIsNotAHardwareID() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let label = LicenseDeviceLabel.make(uuid: uuid)
        XCTAssertEqual(label, "umbilical-aaaaaaaa")
        XCTAssertFalse(label.contains("IOPlatform"))
    }

    func testBuildConfiguration() {
        let debug = LicenseBuild.configuration(
            organizationID: LicenseFixture.organizationID,
            debugBuild: true
        )
        XCTAssertEqual(debug.enforcement, .off)
        XCTAssertNil(debug.organizationID)
        XCTAssertTrue(debug.unofficialNote.contains("Unofficial build"))

        let source = LicenseBuild.configuration(organizationID: "  ", debugBuild: false)
        XCTAssertEqual(source.enforcement, .off)
        XCTAssertTrue(source.unofficialNote.contains("Unofficial build"))
        XCTAssertTrue(source.unofficialNote.contains("organization id"))

        let unsubstituted = LicenseBuild.configuration(
            organizationID: "$(POLAR_ORGANIZATION_ID)",
            debugBuild: false
        )
        XCTAssertEqual(unsubstituted.enforcement, .off)

        let invalid = LicenseBuild.configuration(organizationID: "not-a-uuid", debugBuild: false)
        XCTAssertEqual(invalid.enforcement, .invalidOrganizationID)

        let release = LicenseBuild.configuration(
            organizationID: LicenseFixture.organizationID.uppercased(),
            debugBuild: false
        )
        XCTAssertEqual(release.enforcement, .on)
        XCTAssertEqual(release.organizationID, LicenseFixture.organizationID)
    }

    func testPublicRequestsUseCustomerPortalHTTPSAndNoAuthorization() {
        let body = Data("{\"key\":\"KEY-THIS-0001\"}".utf8)
        let request = PolarRequestBuilder.urlRequest(
            path: PolarLicenseEndpoint.validate.rawValue,
            body: body
        )
        let url = request?.url
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "api.polar.sh")
        XCTAssertEqual(url?.path, "/v1/customer-portal/license-keys/validate")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        let names = Set((request?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertEqual(names, ["accept", "content-type"])
        XCTAssertNil(
            PolarRequestBuilder.urlRequest(path: "/v1/license-keys/validate", body: body)
        )
        XCTAssertNil(PolarRequestBuilder.urlRequest(path: "https://evil.example/key", body: body))
    }

    func testLicenseBlockMessageIsNotRedacted() {
        let message = LicenseCopy.actionBlocked
        XCTAssertEqual(DownloadMessage.text(for: LicenseBlocked(message: message)), message)
        XCTAssertTrue(message.contains("Downloads already running keep going"))
    }

    func testParserIgnoresExtraCustomerFields() throws {
        let raw = """
            {
              "status": "granted",
              "key": "KEY-THIS-0001",
              "organization_id": "11111111-1111-4111-8111-111111111111",
              "customer": {"email": "person@example.com", "extra": true},
              "activation": {"id": "22222222-2222-4222-8222-222222222222"}
            }
            """
        let reading = try XCTUnwrap(PolarLicenseParser.read(Data(raw.utf8)))
        XCTAssertEqual(reading.status, "granted")
        XCTAssertEqual(reading.key, LicenseFixture.key)
        XCTAssertEqual(reading.activationID, LicenseFixture.activationID)
    }
}

private func entitlementsPlist(_ relative: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent(relative))
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try XCTUnwrap(object as? [String: Any])
}

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
