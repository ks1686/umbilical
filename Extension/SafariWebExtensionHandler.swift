// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SafariServices
import UmbilicalEngine

/// Receives a native message from the extension page and opens the app.
/// The message may contain only a URL and an optional file name. The app confirms it.
public class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    public func beginRequest(with context: NSExtensionContext) {
        guard let openURL = handoffURL(in: context) else {
            finish(context, accepted: false)
            return
        }
        context.open(openURL) { accepted in
            self.finish(context, accepted: accepted)
        }
    }

    private func handoffURL(in context: NSExtensionContext) -> URL? {
        guard
            let input = context.inputItems.first as? NSExtensionItem,
            let message = input.userInfo?[SFExtensionMessageKey]
        else {
            return nil
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let handoff = try? ExternalDownload.stage(nativeMessage: message, downloadRoot: root)
        else {
            return nil
        }
        return try? ExternalDownload.openURL(for: handoff, downloadRoot: root)
    }

    private func finish(_ context: NSExtensionContext, accepted: Bool) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: ["accepted": accepted]]
        context.completeRequest(returningItems: [item])
    }
}
