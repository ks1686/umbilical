// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

public enum VideoToggleState {
    /// Known video hosts select Video until the user turns the control on or off.
    public static func resolved(urlText: String, userDidChoose: Bool, current: Bool) -> Bool {
        if userDidChoose {
            return current
        }
        return VideoPagePolicy.prefersVideo(urlText: urlText)
    }
}
