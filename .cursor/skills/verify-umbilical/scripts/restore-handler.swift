import AppKit
import Foundation

// Fallback when the JavaScript restore does not finish. The completion can
// run on another queue, so this waits on a semaphore and also pumps the run
// loop. It gives up after 60 seconds.

final class ResultBox {
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

let deadline = Date().addingTimeInterval(60)
while semaphore.wait(timeout: .now()) == .timedOut {
    if Date() > deadline {
        fputs("handler restore timed out waiting for NSWorkspace\n", stderr)
        exit(1)
    }
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
}

if box.failed {
    fputs(box.message + "\n", stderr)
    exit(1)
}
exit(0)
