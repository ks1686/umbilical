// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Opens a URL the Safari native handler has already built. Tests inject a recorder.
public protocol HandoffURLOpening {
    func open(_ url: URL, completionHandler: @escaping (Bool, Error?) -> Void)
}

/// Stages a native message, then opens only the `umbilical://` URL it builds.
public enum HandoffLaunch {
    public static func urlToOpen(
        fromNativeMessage message: Any,
        downloadRoot: URL
    ) throws -> URL {
        let handoff = try ExternalDownload.stage(
            nativeMessage: message,
            downloadRoot: downloadRoot
        )
        let url = try ExternalDownload.openURL(for: handoff, downloadRoot: downloadRoot)
        guard url.scheme?.lowercased() == ExternalDownload.scheme else {
            throw EngineError.schemeRejected(url.scheme?.lowercased() ?? "")
        }
        let host = url.host?.lowercased() ?? ""
        guard host == ExternalDownload.host || host == ExternalDownload.videoHost else {
            throw EngineError.handoffRejected("host")
        }
        return url
    }

    public static func open(
        nativeMessage: Any,
        downloadRoot: URL,
        opener: HandoffURLOpening,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        let url: URL
        do {
            url = try urlToOpen(
                fromNativeMessage: nativeMessage,
                downloadRoot: downloadRoot
            )
        } catch {
            completionHandler(false, error)
            return
        }
        opener.open(url, completionHandler: completionHandler)
    }
}
