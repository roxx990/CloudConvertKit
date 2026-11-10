# App lifecycle

## iOS

Two small pieces of UIKit glue live in your app, not in the package. First, background transfers deliver their events through the app delegate:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = ConversionServices.engine               // creates the background session early
        Task { _ = await ConversionServices.engine.resumePendingConversions() }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier: identifier,
                                                                      completionHandler: completionHandler)
        _ = ConversionServices.engine
    }
}
```

The handler is never dropped: one that arrives before the engine exists waits for it, and one that arrives just after the session delivered its events is called at once. The system's closure is taken as it is, also in the Swift 6 language mode.

`resumePendingConversions()` returns handles for conversions that were in flight when the app last died, so a processing screen can show them finishing. Conversions running in the current process are never reported as pending or started twice.

Background time between transfers (creating the job, polling, moving the output into place) is asked for by `SystemBackgroundActivity`, the default `backgroundActivity`: `ProcessInfo.performExpiringActivity`, the time `beginBackgroundTask` gives, without UIKit. Set `NoBackgroundActivity()` if your app manages it itself.

## Interrupted conversions

Once its job exists on CloudConvert, a conversion is never thrown away because the network or the time ran out: the job may still finish, or already has, and is paid for. When the network stays away longer than `offlineWaitTimeout` (90 s by default), or `polling.jobTimeout` passes with the job still running, the conversion stops with an error whose `isResumable` is `true`: `.timedOut(phase: .waitingForNetwork)` (also `isConnectivityRelated`) or `.jobTimedOut`. Its last stage is `.failed`; its record, staged input and job are kept, and it is listed by `pendingConversions()`.

Don't start it again, which would create a second job and bill the file twice. Resume it, for example once the device is back online:

```swift
do {
    show(try await handle.result)
} catch let error as CloudConvertError where error.isResumable {
    for await online in ConnectivityMonitor.shared.changes() where online {
        if let resumed = await engine.resumePendingConversions(where: { $0.id == handle.id }).first {
            show(try await resumed.result)
        }
        break
    }
}
```

`resumePendingConversions(where:)` resumes only the records it accepts (by `id`, `key`, or by `userInfo` for conversions your own layer started) and leaves every other record untouched. Otherwise `resumePendingConversions()` at the next launch picks it up, and `discardPendingConversion(id:)` or `discardPendingConversions(where:)` gives it up and deletes the job. `ConversionRecord.canResume` says whether a record still can (its job has not expired, its staged copies are there).

With `resumesWhenOnline = true` the engine does this itself: the conversions this process kept because the network stayed away continue when it returns. Their handles arrive through `engine.automaticResumes()` and `resumedConversion(id:)`, and `ConversionViewModel` follows them. Conversions kept by an earlier launch are left for the app to offer. A request with a `key` simply continues the kept conversion when it is converted again.

A record already running is never resumed twice, so a second caller gets no handle for it. `resumedConversion(id:)` gives that caller another handle on the run, and on its result once it has ended; it returns `nil` for one that failed for good or was cancelled, which starts over.

## macOS

Everything builds and the whole test suite runs natively. There is no `handleEventsForBackgroundURLSession` to wire, so skip that step. A background session lets a transfer survive a quit and re-attach at the next launch, but on some networks `nsurlsessiond` uploads far slower than a standard session; `usesBackgroundTransfers = false` trades that survival for speed. Sandboxed apps get security-scoped `NSOpenPanel` URLs, which staging already handles. The default `SystemBackgroundActivity` holds a `ProcessInfo` activity during a conversion, so App Nap doesn't throttle it; the Mac may still idle-sleep, and a conversion kept meanwhile continues on wake.
