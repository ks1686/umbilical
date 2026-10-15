// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalUI

enum LicenseEnvironment {
    @MainActor
    static func make() -> LicenseService {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PolarOrganizationID") as? String
        // Debug skips the check so a source build is usable. Release uses the
        // organization id from Info.plist, which xcconfig fills in.
        #if DEBUG
            let debugBuild = true
        #else
            let debugBuild = false
        #endif
        let configuration = LicenseBuild.configuration(
            organizationID: raw,
            debugBuild: debugBuild
        )
        return LicenseService(
            runtime: LicenseRuntime(
                configuration: configuration,
                store: KeychainLicenseStore(),
                transport: PolarHTTPTransport(),
                device: PlatformLicenseDevice()
            )
        )
    }
}
