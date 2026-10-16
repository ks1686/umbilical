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
