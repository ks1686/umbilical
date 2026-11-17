import AppKit
import Foundation

// Fallback when the JavaScript restore does not finish.
// The completion can be delivered on the main queue, so the main run loop has to
// be running. The no-argument run loop does not return after that completion,
// so this process polls until the restore finishes or the deadline passes and
// then exits. Exit 0 is success. Exit 1 is a workspace error or a timeout.

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    private var message = ""
    private var didFinish = false

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    func finish(errorText: String?) {
        lock.lock()
        if let errorText = errorText {
            failed = true
            message = errorText
        }
        didFinish = true
        lock.unlock()
    }

    func failureMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if failed {
            return message
        }
        return nil
    }
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
NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "umbilical", completion: { error in
    if let error = error {
        box.finish(errorText: error.localizedDescription)
    } else {
        box.finish(errorText: nil)
    }
})

let deadline = Date().addingTimeInterval(60)
while !box.finished && Date() < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
}

if !box.finished {
    fputs("handler restore timed out waiting for NSWorkspace\n", stderr)
    exit(1)
}
if let message = box.failureMessage() {
    fputs(message + "\n", stderr)
    exit(1)
}
exit(0)
