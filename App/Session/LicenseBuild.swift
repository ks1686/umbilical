// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum LicenseEnforcement: Equatable {
    case off
    case on
    case invalidOrganizationID
}

public struct LicenseConfiguration: Equatable {
    public var organizationID: String?
    public var enforcement: LicenseEnforcement
    public var unofficialNote: String
}

enum OrganizationID {
    case absent
    case invalid
    case valid(String)

    static func parse(_ raw: String?) -> OrganizationID {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.contains("$(") {
            return .absent
        }
        let pattern =
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return .invalid
        }
        return .valid(trimmed.lowercased())
    }
}

public enum LicenseBuild {
    public static func configuration(
        organizationID raw: String?,
        debugBuild: Bool
    ) -> LicenseConfiguration {
        if debugBuild {
            return LicenseConfiguration(
                organizationID: nil,
                enforcement: .off,
                unofficialNote: LicenseCopy.unofficialDebug
            )
        }
        switch OrganizationID.parse(raw) {
        case .absent:
            return LicenseConfiguration(
                organizationID: nil,
                enforcement: .off,
                unofficialNote: LicenseCopy.unofficialSource
            )
        case .invalid:
            return LicenseConfiguration(
                organizationID: nil,
                enforcement: .invalidOrganizationID,
                unofficialNote: ""
            )
        case .valid(let id):
            return LicenseConfiguration(
                organizationID: id,
                enforcement: .on,
                unofficialNote: ""
            )
        }
    }
}
