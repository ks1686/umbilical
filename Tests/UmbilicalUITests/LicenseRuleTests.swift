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

#if os(macOS)
    final class LicenseKeychainAttributeTests: XCTestCase {
        func testItemsAreAfterFirstUnlockThisDeviceOnly() {
            let data = Data("validation".utf8)
            let add = KeychainLicenseStore.addAttributes(
                service: "me.peapod.umbilical.license",
                account: "validation",
                data: data
            )
            XCTAssertEqual(
                add[kSecAttrAccessible as String] as? String,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
            XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
            let lookup = KeychainLicenseStore.lookupAttributes(
                service: "me.peapod.umbilical.license",
                account: "validation"
            )
            XCTAssertEqual(lookup[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertNil(lookup[kSecAttrAccessible as String])
        }
    }
#endif
