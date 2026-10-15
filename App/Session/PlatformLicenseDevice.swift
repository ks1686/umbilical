// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public protocol LicenseDeviceIdentifying: AnyObject {
    func currentDeviceID() -> String?
}

#if os(macOS)
    import IOKit

    public final class PlatformLicenseDevice: LicenseDeviceIdentifying {
        public init() {}

        /// SHA-256 of IOPlatformUUID. The raw platform id is not returned.
        public func currentDeviceID() -> String? {
            guard let uuid = IOPlatformUUID.string(), !uuid.isEmpty else { return nil }
            return SHA256Hex.digest(uuid)
        }
    }

    enum IOPlatformUUID {
        static func string() -> String? {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPlatformExpertDevice")
            )
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            return property(service)
        }

        private static func property(_ service: io_registry_entry_t) -> String? {
            guard
                let unmanaged = IORegistryEntryCreateCFProperty(
                    service,
                    kIOPlatformUUIDKey as CFString,
                    kCFAllocatorDefault,
                    0
                )
            else { return nil }
            return unmanaged.takeRetainedValue() as? String
        }
    }
#endif
