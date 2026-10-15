// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Public customer-portal routes. These calls send the organization id and
/// the license key. They do not send an access token.
public enum PolarLicenseEndpoint: String, Equatable {
    case activate = "/v1/customer-portal/license-keys/activate"
    case validate = "/v1/customer-portal/license-keys/validate"
    case deactivate = "/v1/customer-portal/license-keys/deactivate"

    public static let host = "api.polar.sh"

    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = rawValue
        guard components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

public struct PolarCall: Equatable, Sendable {
    public var path: String
    public var body: Data

    public init(path: String, body: Data) {
        self.path = path
        self.body = body
    }
}

public struct PolarReply: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol LicenseTransport: AnyObject {
    func send(_ call: PolarCall) async throws -> PolarReply
}

enum PolarLicenseRequest {
    static func activate(key: String, organizationID: String, label: String) -> PolarCall {
        call(
            .activate,
            [
                "key": key,
                "organization_id": organizationID,
                "label": label
            ]
        )
    }

    static func validate(
        key: String,
        organizationID: String,
        activationID: String
    ) -> PolarCall {
        call(
            .validate,
            [
                "key": key,
                "organization_id": organizationID,
                "activation_id": activationID
            ]
        )
    }

    static func deactivate(
        key: String,
        organizationID: String,
        activationID: String
    ) -> PolarCall {
        call(
            .deactivate,
            [
                "key": key,
                "organization_id": organizationID,
                "activation_id": activationID
            ]
        )
    }

    private static func call(
        _ endpoint: PolarLicenseEndpoint,
        _ fields: [String: String]
    ) -> PolarCall {
        let body =
            (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return PolarCall(path: endpoint.rawValue, body: body)
    }
}

enum PolarRequestBuilder {
    static func urlRequest(path: String, body: Data) -> URLRequest? {
        guard let endpoint = PolarLicenseEndpoint(rawValue: path), let url = endpoint.url else {
            return nil
        }
        guard url.scheme == "https", url.host == PolarLicenseEndpoint.host else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }
}

enum PolarStatus {
    enum Kind {
        case success
        case forbidden
        case notFound
        case unavailable
    }

    static func kind(_ code: Int) -> Kind {
        switch code {
        case 200, 204:
            return .success
        case 403:
            return .forbidden
        case 404:
            return .notFound
        default:
            return .unavailable
        }
    }
}

struct PolarLicenseReading: Equatable {
    var status: String
    var key: String?
    var organizationID: String?
    var activationID: String?
    var expiresAt: Date?
    var serverTime: Date?
}

enum PolarLicenseParser {
    static func read(_ data: Data) -> PolarLicenseReading? {
        guard let object = jsonObject(data) else { return nil }
        if let license = object["license_key"] as? [String: Any] {
            return readActivation(object, license: license)
        }
        return readValidation(object)
    }

    private static func readActivation(
        _ object: [String: Any],
        license: [String: Any]
    ) -> PolarLicenseReading? {
        guard let status = license["status"] as? String else { return nil }
        guard let activationID = object["id"] as? String, !activationID.isEmpty else { return nil }
        return PolarLicenseReading(
            status: status,
            key: license["key"] as? String,
            organizationID: license["organization_id"] as? String,
            activationID: activationID,
            expiresAt: PolarDate.parse(license["expires_at"]),
            serverTime: PolarDate.parse(object["created_at"])
                ?? PolarDate.parse(license["last_validated_at"])
        )
    }

    private static func readValidation(_ object: [String: Any]) -> PolarLicenseReading? {
        guard let status = object["status"] as? String else { return nil }
        let activation = object["activation"] as? [String: Any]
        return PolarLicenseReading(
            status: status,
            key: object["key"] as? String,
            organizationID: object["organization_id"] as? String,
            activationID: activation?["id"] as? String,
            expiresAt: PolarDate.parse(object["expires_at"]),
            serverTime: PolarDate.parse(object["last_validated_at"])
        )
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum PolarDate {
    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

enum PolarGrant {
    /// Nil means the key is granted and not expired.
    static func block(status: String, expiresAt: Date?, now: Date) -> LicenseServerBlock? {
        switch status {
        case "granted":
            if let expiresAt, expiresAt <= now {
                return .expired
            }
            return nil
        case "revoked":
            return .revoked
        case "disabled":
            return .disabled
        default:
            return .rejected
        }
    }
}
