// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

public enum DownloadMessage {
    public static func text(for error: Error) -> String {
        redact(describe(error))
    }

    static func redact(_ text: String) -> String {
        text.replacingOccurrences(
            of: "token:[0-9A-Fa-f]+",
            with: "token:[redacted]",
            options: .regularExpression
        )
    }

    private static func describe(_ error: Error) -> String {
        if let session = error as? SessionError {
            return session.description
        }
        guard let engine = error as? EngineError else {
            return error.localizedDescription
        }
        return describe(engine)
    }

    // One arm per engine error so a new case has to be classified here.
    private static func describe(_ error: EngineError) -> String {
        switch error {
        case .schemeRejected(let scheme):
            return schemeMessage(scheme)
        case .directoryRejected:
            return "That folder cannot be used."
        case .outputNameRejected:
            return "The file name cannot include a path."
        case .handoffRejected:
            return "That download request was rejected."
        case .executableMissing(let path):
            return missingHelper(path)
        case .videoRejected(let detail):
            return detail
        case .temporaryDirectoryFailed,
            .settingsWriteFailed,
            .settingsPermissions,
            .launchFailed,
            .listenTimeout,
            .secretExposed,
            .hookRejected,
            .optionRejected,
            .optionValueRejected,
            .quarantineFailed,
            .rpc,
            .transport,
            .unexpectedStatus,
            .torrentRejected,
            .magnetRejected,
            .notSupported:
            return error.description
        }
    }

    private static func missingHelper(_ path: String) -> String {
        if path == "yt-dlp" {
            return "Missing yt-dlp. Release builds use Contents/Helpers only. "
                + "Debug builds also honor YT_DLP."
        }
        return "Missing helper: \(path)"
    }

    private static func schemeMessage(_ scheme: String) -> String {
        switch scheme {
        case "", "empty", "unparseable", "whitespace":
            return "Enter an http or https URL."
        case "userinfo":
            return "URLs that include a username or password are rejected."
        default:
            return "Only http and https URLs can be added (\(scheme))."
        }
    }
}
