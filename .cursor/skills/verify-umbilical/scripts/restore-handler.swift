import AppKit
import Foundation

// Fallback when the JavaScript restore does not finish.
// The completion can be delivered on the main queue, so the main run loop has to be running.
// A timer stops the wait after 60 seconds.

final class ResultBox: @unchecked Sendable {
    var failed = false
    var message = ""
    var finished = false
}

let arguments = CommandLine.arguments
if arguments.count != 3 {
    fputs("usage: restore-handler APP_PATH SCHEME\n", stderr)
    exit(2)
}

let appURL = URL(fileURLWithPath: arguments[1])
let scheme = arguments[2]
if scheme != "umbilical" {
    fputs("restore-handler only restores the umbilical scheme\n", stderr)
    exit(2)
}

let box = ResultBox()
let timer = Timer(timeInterval: 60, repeats: false) { _ in
    if !box.finished {
        fputs("handler restore timed out waiting for NSWorkspace\n", stderr)
        exit(1)
    }
}

NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "umbilical", completion: { error in
    if let error = error {
        box.failed = true
        box.message = error.localizedDescription
    }
    box.finished = true
    CFRunLoopStop(CFRunLoopGetMain())
})

RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()

if box.failed {
    fputs(box.message + "\n", stderr)
    exit(1)
}
exit(0)
