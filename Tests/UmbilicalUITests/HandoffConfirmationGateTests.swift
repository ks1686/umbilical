// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class HandoffConfirmationGateTests: XCTestCase {
    func testReturnAndEarlyClicksDoNotConfirm() {
        let opened = Date(timeIntervalSince1970: 1_000)
        let gate = HandoffConfirmationGate(appearedAt: opened)
        let early = opened.addingTimeInterval(0.2)
        XCTAssertEqual(gate.decide(.return, at: early), .ignore)
        XCTAssertEqual(gate.decide(.download, at: early), .ignore)
        XCTAssertEqual(gate.decide(.cancel, at: early), .ignore)

        let justBefore = opened.addingTimeInterval(HandoffConfirmationGate.armDelay - 0.001)
        XCTAssertEqual(gate.decide(.download, at: justBefore), .ignore)
        XCTAssertEqual(gate.decide(.return, at: justBefore), .ignore)

        let armed = opened.addingTimeInterval(HandoffConfirmationGate.armDelay)
        XCTAssertEqual(gate.decide(.return, at: armed), .decline)
        XCTAssertNotEqual(gate.decide(.return, at: armed), .confirm)
        XCTAssertEqual(gate.decide(.cancel, at: armed), .decline)
        XCTAssertEqual(gate.decide(.download, at: armed), .confirm)
    }

    func testProminentLabelIsTheHost() throws {
        let https = try XCTUnwrap(URL(string: "https://downloads.example.com:443/a.bin"))
        XCTAssertEqual(HandoffConfirmationGate.prominentLabel(for: https), "downloads.example.com")
        let magnetText = "magnet:?xt=urn:btih:" + String(repeating: "ab", count: 20)
        let magnet = try XCTUnwrap(URL(string: magnetText))
        XCTAssertEqual(HandoffConfirmationGate.prominentLabel(for: magnet), "magnet")
    }
}
