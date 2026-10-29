//  Lets the host app keep the process alive for a short while after it is
//  backgrounded without the kit importing UIKit. `SystemBackgroundActivity`
//  (the default) does it with Foundation alone. Uploads and downloads already run on a background URLSession; this
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

/// Does nothing: for an app that manages background time itself.
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

/// The default, with Foundation alone:
/// - macOS: a `ProcessInfo` activity, so App Nap doesn't throttle polling
///   and the move into place. The Mac may still idle-sleep; a conversion
///   kept meanwhile continues on wake.
/// - iOS: `ProcessInfo.performExpiringActivity`, the background time
///   `beginBackgroundTask` gives, without UIKit. When the system takes it
///   back the conversion simply carries on at the next launch or resume.
public final class SystemBackgroundActivity: BackgroundActivityProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var next = 1
    #if os(macOS)
    private var activities: [Int: NSObjectProtocol] = [:]
    #else
    private var releases: [Int: DispatchSemaphore] = [:]
    #endif

    public init() {}

    public func beginActivity(named name: String) -> BackgroundActivityToken? {
        lock.lock()
        let id = next
        next += 1
        lock.unlock()
        #if os(macOS)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: name)
        lock.lock(); activities[id] = activity; lock.unlock()
        #else
        // The activity lasts while its block runs, so the block waits, on
        // a thread of its own, until `endActivity` (or the system, with
        // `expired`) releases it.
        let release = DispatchSemaphore(value: 0)
        lock.lock(); releases[id] = release; lock.unlock()
        ProcessInfo.processInfo.performExpiringActivity(withReason: name) { expired in
            if expired { release.signal() } else { release.wait() }
        }
        #endif
        return BackgroundActivityToken(rawValue: id)
    }

    public func endActivity(_ token: BackgroundActivityToken) {
        lock.lock()
        #if os(macOS)
        let activity = activities.removeValue(forKey: token.rawValue)
        lock.unlock()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        #else
        let release = releases.removeValue(forKey: token.rawValue)
        lock.unlock()
        release?.signal()
        #endif
    }
}
