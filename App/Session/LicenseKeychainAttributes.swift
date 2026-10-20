// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum LicenseKeychainAccount {
    static let label = "device-label"
    static let credential = "credential"
    static let validation = "validation"
    static let all = [label, credential, validation]
}

/// Team id plus `me.peapod.umbilical`. The only access group the app claims.
enum LicenseKeychainAccessGroup {
    static let bundleID = "me.peapod.umbilical"
    static let placeholder = "$(AppIdentifierPrefix)" + bundleID

    static func onlyAppGroup(in groups: [String]) -> String? {
        guard groups.count == 1, let group = groups.first else { return nil }
        let suffix = "." + bundleID
        guard group.hasSuffix(suffix) else { return nil }
        let team = String(group.dropLast(suffix.count))
        guard isTeamID(team) else { return nil }
        return group
    }

    private static func isTeamID(_ team: String) -> Bool {
        guard team.count == 10 else { return false }
        return team.allSatisfy { character in
            guard let ascii = character.asciiValue else { return false }
            let digit = ascii >= 48 && ascii <= 57
            let upper = ascii >= 65 && ascii <= 90
            return digit || upper
        }
    }
}

/// Reads the access group from a `SecCodeCopySigningInformation` dictionary.
enum SignedLicenseAccessGroup {
    /// `kSecCodeInfoEntitlements`. The value is the raw entitlements blob.
    static let entitlementsBlobKey = "entitlements"
    /// `kSecCodeInfoEntitlementsDict`. The value is the entitlements dictionary.
    static let entitlementsDictionaryKey = "entitlements-dict"
    static let releaseGroup = "7R2VPW8GH4." + LicenseKeychainAccessGroup.bundleID

    static func accessGroup(from signingInformation: [String: Any]) -> String? {
        guard let entitlements = dictionary(signingInformation[entitlementsDictionaryKey]) else {
            return nil
        }
        guard let listed = stringList(entitlements["keychain-access-groups"]) else { return nil }
        guard let group = LicenseKeychainAccessGroup.onlyAppGroup(in: listed) else { return nil }
        guard group == releaseGroup else { return nil }
        return group
    }

    private static func dictionary(_ raw: Any?) -> [String: Any]? {
        if let values = raw as? [String: Any] { return values }
        guard let values = raw as? NSDictionary else { return nil }
        var listed: [String: Any] = [:]
        for case (let key as String, let value) in values {
            listed[key] = value
        }
        guard listed.count == values.count else { return nil }
        return listed
    }

    private static func stringList(_ raw: Any?) -> [String]? {
        if let groups = raw as? [String] { return groups }
        if let groups = raw as? [Any] { return completeStrings(groups) }
        guard let groups = raw as? NSArray else { return nil }
        var listed: [Any] = []
        for item in groups {
            listed.append(item)
        }
        return completeStrings(listed)
    }

    private static func completeStrings(_ groups: [Any]) -> [String]? {
        let listed = groups.compactMap { $0 as? String }
        guard listed.count == groups.count else { return nil }
        return listed
    }
}

struct LicenseKeychainQuery: Equatable {
    var service: String
    var account: String
    var accessGroup: String?
    var useDataProtectionKeychain: Bool
    var synchronizable: Bool?
    /// Login-keychain deletes match items whether or not sync was stored.
    var matchAnySynchronizable: Bool
    var accessible: LicenseKeychainAccessibility?
    var returnsData: Bool
}

enum LicenseKeychainQueries {
    static func dataProtection(
        service: String,
        account: String,
        accessGroup: String,
        storing: Bool
    ) -> LicenseKeychainQuery {
        let policy = LicenseKeychainPolicy.item
        return LicenseKeychainQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: policy.useDataProtectionKeychain,
            synchronizable: policy.synchronizable,
            matchAnySynchronizable: false,
            accessible: storing ? policy.accessible : nil,
            returnsData: false
        )
    }

    /// Removes a pre-release copy from the file-based login keychain.
    /// This query never carries secret bytes.
    static func legacyLoginDelete(service: String, account: String) -> LicenseKeychainQuery {
        LicenseKeychainQuery(
            service: service,
            account: account,
            accessGroup: nil,
            useDataProtectionKeychain: false,
            synchronizable: nil,
            matchAnySynchronizable: true,
            accessible: nil,
            returnsData: false
        )
    }
}

enum LicenseKeychainWriteGuard {
    static func targetsDataProtection(_ query: LicenseKeychainQuery) -> Bool {
        query.useDataProtectionKeychain
            && query.synchronizable == false
            && query.accessGroup != nil
            && !query.matchAnySynchronizable
    }

    static func canStore(_ query: LicenseKeychainQuery) -> Bool {
        targetsDataProtection(query)
            && query.accessible == LicenseKeychainPolicy.item.accessible
    }

    static func targetsLegacyLogin(_ query: LicenseKeychainQuery) -> Bool {
        !query.useDataProtectionKeychain
            && query.accessGroup == nil
            && query.accessible == nil
            && query.synchronizable == nil
            && query.matchAnySynchronizable
            && !query.returnsData
    }
}
