// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import UmbilicalUI
import UserNotifications

enum DownloadNotifier {
    static func post(_ notice: DownloadNotice) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            let request = UNNotificationRequest(
                identifier: notice.id,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
