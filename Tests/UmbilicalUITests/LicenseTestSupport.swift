// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalUI

enum LicenseFixture {
    static let organizationID = "11111111-1111-4111-8111-111111111111"
    static let activationID = "22222222-2222-4222-8222-222222222222"
    static let key = "KEY-THIS-0001"
    static let otherKey = "KEY-OTHER-0002"
    static let deviceID = "device-this-aaaaaaaaaaaaaaaa"
    static let otherDeviceID = "device-other-bbbbbbbbbbbbbbbb"
    static let label = "umbilical-abcdef01"

    static func credential(
        key: String = key,
        deviceID: String = deviceID,
        block: LicenseServerBlock? = nil
    ) -> LicenseCredential {
        LicenseCredential(
            key: key,
            activationID: activationID,
            deviceID: deviceID,
            block: block
        )
    }

    static func validation(
        key: String = key,
        deviceID: String = deviceID,
        validatedAt: Date,
        observedAt: Date? = nil
    ) -> LicenseValidationRecord {
        LicenseValidationRecord(
            key: key,
            activationID: activationID,
            deviceID: deviceID,
            validatedAt: validatedAt,
            observedAt: observedAt ?? validatedAt
        )
    }

    static func validationData(
        status: String,
        key: String = key,
        serverTime: String? = nil
    ) throws -> Data {
        var fields: [String: Any] = [
            "status": status,
            "key": key,
            "organization_id": organizationID,
            "activation": ["id": activationID]
        ]
        if let serverTime {
            fields["last_validated_at"] = serverTime
        }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    static func activationData(
        status: String = "granted",
        key: String = key,
        createdAt: String? = nil
    ) throws -> Data {
        let license: [String: Any] = [
            "status": status,
            "key": key,
            "organization_id": organizationID
        ]
        var root: [String: Any] = [
            "id": activationID,
            "license_key": license
        ]
        if let createdAt {
            root["created_at"] = createdAt
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}

final class ManualClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class StubLicenseDevice: LicenseDeviceIdentifying {
    var identifier: String?
    init(_ identifier: String?) { self.identifier = identifier }
    func currentDeviceID() -> String? { identifier }
}

struct StubLicenseError: Error {}

final class StubLicenseTransport: LicenseTransport {
    var results: [Result<PolarReply, Error>]
    private(set) var calls: [PolarCall] = []

    init(_ results: [Result<PolarReply, Error>] = []) {
        self.results = results
    }

    func send(_ call: PolarCall) async throws -> PolarReply {
        calls.append(call)
        if results.isEmpty {
            throw StubLicenseError()
        }
        return try results.removeFirst().get()
    }
}

func licenseDenial(_ status: LicenseStatus) -> LicenseDenial? {
    if case .unlicensed(let denial) = status { return denial }
    return nil
}

func licenseJSON(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
}

struct LicenseHarnessOptions {
    var device = StubLicenseDevice(LicenseFixture.deviceID)
    var enforcement = LicenseEnforcement.on
    var note = "Unofficial build. License checks are off."
}

@MainActor
func makeLicenseService(
    store: MemoryLicenseStore = MemoryLicenseStore(),
    transport: StubLicenseTransport = StubLicenseTransport(),
    clock: ManualClock,
    options: LicenseHarnessOptions = LicenseHarnessOptions(),
    log: @escaping @MainActor (String) -> Void = { _ in }
) -> LicenseService {
    let configuration = LicenseConfiguration(
        organizationID: options.enforcement == .on ? LicenseFixture.organizationID : nil,
        enforcement: options.enforcement,
        unofficialNote: options.note
    )
    return LicenseService(
        runtime: LicenseRuntime(
            configuration: configuration,
            store: store,
            transport: transport,
            device: options.device
        ),
        hooks: LicenseHooks(
            clock: { clock.now },
            makeLabel: { LicenseFixture.label },
            log: log
        )
    )
}

func polarReply(status: Int, body: Data = Data()) -> PolarReply {
    PolarReply(statusCode: status, body: body)
}
