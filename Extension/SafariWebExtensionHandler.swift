// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SafariServices
import UmbilicalEngine

/// Opens only an `umbilical://` URL this process built after staging.
private struct WorkspaceHandoffURLOpener: HandoffURLOpening {
    func open(_ url: URL, completionHandler: @escaping (Bool, Error?) -> Void) {
        guard url.scheme?.lowercased() == ExternalDownload.scheme else {
            completionHandler(false, EngineError.schemeRejected(url.scheme ?? ""))
            return
        }
        NSWorkspace.shared.open(
            url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            completionHandler(error == nil, error)
        }
    }
}

/// Receives a native message from the extension page and opens the app.
/// The message may contain only a URL and an optional file name. The app confirms it.
/// Never opens a URL taken from the message; only the staged `umbilical://` URL.
public class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    let opener: HandoffURLOpening

    public override init() {
        opener = WorkspaceHandoffURLOpener()
        super.init()
    }

    init(opener: HandoffURLOpening) {
        self.opener = opener
        super.init()
    }

    public func beginRequest(with context: NSExtensionContext) {
        guard
            let input = context.inputItems.first as? NSExtensionItem,
            let message = input.userInfo?[SFExtensionMessageKey]
        else {
            finish(context, accepted: false)
            return
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        HandoffLaunch.open(
            nativeMessage: message,
            downloadRoot: root,
            opener: opener
        ) { accepted, error in
            if let error {
                NSLog(
                    "umbilical native handoff open failed: \(error.localizedDescription)"
                )
            }
            self.finish(context, accepted: accepted)
        }
    }

    private func finish(_ context: NSExtensionContext, accepted: Bool) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: ["accepted": accepted]]
        context.completeRequest(returningItems: [item])
    }
}
