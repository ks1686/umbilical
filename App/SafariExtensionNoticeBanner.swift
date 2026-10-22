// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct SafariExtensionNoticeBanner: View {
    @ObservedObject var notice: SafariExtensionNoticeController

    var body: some View {
        if notice.isVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(SafariExtensionNotice.message)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Button(SafariExtensionNotice.openPreferencesTitle) {
                        SafariExtensionBridge.showPreferences()
                    }
                    Button(SafariExtensionNotice.dismissTitle) {
                        notice.dismiss()
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}
