// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import UmbilicalEngine
import XCTest

@testable import UmbilicalUI

final class DownloadMessageTests: XCTestCase {
    func testSchemeMessagesStayGeneric() {
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.schemeRejected("empty")),
            "Enter an http or https URL."
        )
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.schemeRejected("magnet")),
            "That URL scheme is not allowed (magnet)."
        )
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.schemeRejected("option")),
            "That URL cannot be used as a command option."
        )
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.schemeRejected("userinfo")),
            "URLs that include a username or password are rejected."
        )
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.outputNameRejected("../x")),
            "The file name cannot include a path."
        )
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.handoffRejected("cookie")),
            "That download request was rejected."
        )
        XCTAssertFalse(
            DownloadMessage.text(for: EngineError.handoffRejected("cookie")).contains("cookie")
        )
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.directoryRejected("/tmp")),
            "That folder cannot be used."
        )
    }

    func testSessionErrorsPassThrough() {
        XCTAssertEqual(
            DownloadMessage.text(for: SessionError.folderChangeBlocked),
            SessionError.folderChangeBlocked.description
        )
    }

    func testVideoHelperAndRejectionMessages() {
        XCTAssertEqual(
            DownloadMessage.text(for: EngineError.executableMissing("yt-dlp")),
            "Missing yt-dlp. Release builds use Contents/Helpers only. "
                + "Debug builds also honor YT_DLP."
        )
        let text = DownloadMessage.text(for: EngineError.videoRejected("bad token:abcdef"))
        XCTAssertFalse(text.contains("abcdef"))
        XCTAssertTrue(text.contains("token:[redacted]"))
    }

    func testRPCTokenIsRedacted() {
        let error = EngineError.rpc(code: 1, message: "bad token:abcdef")
        let text = DownloadMessage.text(for: error)
        XCTAssertFalse(text.contains("abcdef"))
        XCTAssertTrue(text.contains("token:[redacted]"))
        XCTAssertFalse(text.contains("\u{2014}"))
    }
}
