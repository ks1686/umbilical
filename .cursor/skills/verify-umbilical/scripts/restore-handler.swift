import AppKit
import Foundation

// Fallback when the JavaScript restore does not finish.
// The completion may run on another queue. Wait on the semaphore and give up after 60 seconds.

final class ResultBox: @unchecked Sendable {
    var failed = false
    var message = ""
}

let arguments = CommandLine.arguments
if arguments.count != 3 {
    fputs("usage: restore-handler APP_PATH SCHEME\n", stderr)
    exit(2)
}

let appURL = URL(fileURLWithPath: arguments[1])
let scheme = arguments[2]
let box = ResultBox()
let semaphore = DispatchSemaphore(value: 0)

NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme, completion: { error in
    if let error = error {
        box.failed = true
        box.message = error.localizedDescription
    }
    semaphore.signal()
})

if semaphore.wait(timeout: .now() + 60) == .timedOut {
    fputs("handler restore timed out waiting for NSWorkspace\n", stderr)
    exit(1)
}

if box.failed {
    fputs(box.message + "\n", stderr)
    exit(1)
}
exit(0)
