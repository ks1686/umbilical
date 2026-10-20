// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

#if os(macOS)
    import Security
#endif

final class LicenseAccessGroupParsingTests: XCTestCase {
    private let releaseGroup = "7R2VPW8GH4.me.peapod.umbilical"

    func testRealEntitlementsDictionaryReturnsTheAppGroup() {
        let signing = signingInformation(groups: [releaseGroup])
        XCTAssertEqual(SignedLicenseAccessGroup.accessGroup(from: signing), releaseGroup)
    }

    func testDataUnderTheOldEntitlementsKeyReturnsNil() {
        let signing: [String: Any] = [
            SignedLicenseAccessGroup.entitlementsBlobKey: Data("signed-entitlements".utf8)
        ]
        XCTAssertNil(SignedLicenseAccessGroup.accessGroup(from: signing))
    }

    func testDictionaryUnderTheOldEntitlementsKeyReturnsNil() {
        let entitlements = entitlementsDictionary(groups: [releaseGroup])
        let signing = [SignedLicenseAccessGroup.entitlementsBlobKey: entitlements]
        XCTAssertNil(SignedLicenseAccessGroup.accessGroup(from: signing))
    }

    func testMissingEntitlementsDictionaryReturnsNil() {
        XCTAssertNil(SignedLicenseAccessGroup.accessGroup(from: [:]))
    }

    func testWildcardAccessGroupReturnsNil() {
        let signing = signingInformation(groups: ["7R2VPW8GH4.*"])
        XCTAssertNil(SignedLicenseAccessGroup.accessGroup(from: signing))
    }

    func testWrongTeamAccessGroupReturnsNil() {
        let signing = signingInformation(groups: ["AB12CD34EF.me.peapod.umbilical"])
        XCTAssertNil(SignedLicenseAccessGroup.accessGroup(from: signing))
    }

    private func signingInformation(groups: [String]) -> [String: Any] {
        [
            SignedLicenseAccessGroup.entitlementsBlobKey: Data("signed-entitlements".utf8),
            SignedLicenseAccessGroup.entitlementsDictionaryKey: entitlementsDictionary(
                groups: groups
            )
        ]
    }

    private func entitlementsDictionary(groups: [String]) -> NSDictionary {
        NSDictionary(dictionary: [
            "keychain-access-groups": NSArray(array: groups)
        ])
    }
}

#if os(macOS)
    final class LicenseCurrentAccessGroupTests: XCTestCase {
        func testCurrentAccessGroupIsNilOnTheAdHocTestHost() {
            XCTAssertNil(SignedLicenseAccessGroup.current())
        }

        func testSigningKeysMatchTheEntitlementsDictionary() {
            XCTAssertEqual(
                kSecCodeInfoEntitlements as String,
                SignedLicenseAccessGroup.entitlementsBlobKey
            )
            XCTAssertEqual(
                kSecCodeInfoEntitlementsDict as String,
                SignedLicenseAccessGroup.entitlementsDictionaryKey
            )
        }
    }
#endif
