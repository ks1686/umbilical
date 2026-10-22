// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum EngineError: Error, Equatable, CustomStringConvertible {
    case temporaryDirectoryFailed(String)
    case settingsWriteFailed(String)
    case settingsPermissions(String)
    case executableMissing(String)
    case launchFailed(String)
    case listenTimeout
    case secretExposed(String)
    case schemeRejected(String)
    case hookRejected(String)
    case optionRejected(String)
    case directoryRejected(String)
    case outputNameRejected(String)
    case optionValueRejected(String)
    case quarantineFailed(String)
    case rpc(code: Int, message: String)
    case transport(String)
    case unexpectedStatus(String)
    case torrentRejected(String)
    case magnetRejected(String)
    case metalinkRejected(String)
    case notSupported(String)
    case handoffRejected(String)
    case videoRejected(String)

    public var description: String {
        switch self {
        case .temporaryDirectoryFailed(let detail):
            return "temporary directory failed: \(detail)"
        case .settingsWriteFailed(let detail):
            return "settings write failed: \(detail)"
        case .settingsPermissions(let detail):
            return "settings permissions failed: \(detail)"
        case .executableMissing(let path):
            return "executable missing: \(path)"
        case .launchFailed(let detail):
            return "launch failed: \(detail)"
        case .listenTimeout:
            return "aria2 did not start listening"
        case .secretExposed(let location):
            return "RPC secret appeared in process arguments or the environment (\(location))"
        case .schemeRejected(let scheme):
            return "scheme rejected: \(scheme)"
        case .hookRejected(let name):
            return "hook option rejected: \(name)"
        case .optionRejected(let name):
            return "option rejected: \(name)"
        case .directoryRejected(let path):
            return "directory rejected: \(path)"
        case .outputNameRejected(let name):
            return "output name rejected: \(name)"
        case .optionValueRejected(let name):
            return "option value rejected: \(name)"
        case .quarantineFailed(let detail):
            return "quarantine failed: \(detail)"
        case .rpc(let code, let message):
            return "rpc error \(code): \(message)"
        case .transport(let detail):
            return "transport error: \(detail)"
        case .unexpectedStatus(let status):
            return "unexpected download status: \(status)"
        case .torrentRejected(let detail):
            return "torrent rejected: \(detail)"
        case .magnetRejected(let detail):
            return "magnet rejected: \(detail)"
        case .metalinkRejected(let detail):
            return "metalink rejected: \(detail)"
        case .notSupported(let feature):
            return "not supported: \(feature)"
        case .handoffRejected(let reason):
            return "handoff rejected: \(reason)"
        case .videoRejected(let detail):
            return detail
        }
    }
}
