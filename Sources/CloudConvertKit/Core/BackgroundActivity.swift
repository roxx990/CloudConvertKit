//  Lets the host app keep the process alive for a short while after it is
//  backgrounded (UIKit's `beginBackgroundTask`) without the kit importing
//  UIKit. Uploads and downloads already run on a background URLSession; this
//  only matters for the seconds between them (creating the job, polling,
//  moving the output into place).
//

import Foundation

/// Opaque handle returned by `beginActivity`. Wraps whatever the platform
/// uses (`UIBackgroundTaskIdentifier.rawValue` on iOS).
public struct BackgroundActivityToken: Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public protocol BackgroundActivityProviding: Sendable {
    /// Ask the system for extra execution time. Return `nil` when unavailable.
    func beginActivity(named name: String) -> BackgroundActivityToken?
    /// Always called exactly once per non-nil token, on any thread.
    func endActivity(_ token: BackgroundActivityToken)
}

/// Default: does nothing. Correct for macOS and for apps that prefer not to
/// request background time.
public struct NoBackgroundActivity: BackgroundActivityProviding {
    public init() {}
    public func beginActivity(named name: String) -> BackgroundActivityToken? { nil }
    public func endActivity(_ token: BackgroundActivityToken) {}
}

// An iOS app implements the protocol in about ten lines and injects it via
// `CloudConvertConfiguration.backgroundActivity`:
//
//     struct UIKitBackgroundActivity: BackgroundActivityProviding {
//         func beginActivity(named name: String) -> BackgroundActivityToken? {
//             var identifier = UIBackgroundTaskIdentifier.invalid
//             identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
//                 UIApplication.shared.endBackgroundTask(identifier)   // expiration: must end it
//                 identifier = .invalid
//             }
//             return identifier == .invalid ? nil : BackgroundActivityToken(rawValue: identifier.rawValue)
//         }
//         func endActivity(_ token: BackgroundActivityToken) {
//             UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
//         }
//     }
