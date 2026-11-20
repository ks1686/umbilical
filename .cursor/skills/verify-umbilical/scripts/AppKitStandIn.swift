// Linux stand-in for the NSWorkspace members restore-handler.swift calls.
// macOS compiles that file against AppKit, so this body is absent there.
#if !canImport(AppKit)
    import Foundation

    // https://developer.apple.com/documentation/appkit/nsworkspace
    public final class NSWorkspace {
        // https://developer.apple.com/documentation/appkit/nsworkspace/shared
        public class var shared: NSWorkspace {
            NSWorkspace()
        }

        // https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)
        public func setDefaultApplication(
            at applicationURL: URL,
            toOpenURLsWithScheme urlScheme: String,
            completion completionHandler: (@Sendable (Error?) -> Void)? = nil
        ) {
            let mode = ProcessInfo.processInfo.environment["UMB_RESTORE_STANDIN"] ?? ""
            struct StandInError: LocalizedError {
                var errorDescription: String? {
                    "workspace refused the handler"
                }
            }
            switch mode {
            case "ok":
                DispatchQueue.main.async {
                    completionHandler?(nil)
                }
            case "error":
                DispatchQueue.main.async {
                    completionHandler?(StandInError())
                }
            default:
                break
            }
            _ = applicationURL
            _ = urlScheme
        }
    }
#endif
