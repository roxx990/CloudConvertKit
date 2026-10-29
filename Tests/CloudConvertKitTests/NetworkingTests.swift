//  Retries, credentials, cancellation shielding and connectivity.
//

import XCTest
import Network
@testable import CloudConvertKit

// MARK: - Retry policy

final class RetryPolicyTests: XCTestCase {

    func testDelaysGrowAndCap() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 5, multiplier: 2, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 5, "capped at maxDelay")
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 4))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 5))
    }

    func testJitterStaysWithinBounds() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 2, maxDelay: 10, multiplier: 2, jitter: 0.5)
        for _ in 0..<100 {
            let delay = policy.delay(forAttempt: 2) // raw = 4 → 2…4
            XCTAssertGreaterThanOrEqual(delay, 2)
            XCTAssertLessThanOrEqual(delay, 4)
        }
    }

    func testRetryingStopsOnNonRetryableError() async {
        let counter = Counter()
        do {
            let _: Int = try await retrying(policy: .api, phase: .creatingJob, logger: SilentCloudConvertLogger(), label: "t",
                                            operation: { () async throws -> Int in
                counter.increment()
                throw CloudConvertError.validation(nil)
            })
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(counter.value, 1)
        }
    }

    func testRetryingHonoursRetryAfterAndSucceeds() async throws {
        let counter = Counter()
        let started = Date()
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.01, jitter: 0)
        let value: Int = try await retrying(policy: policy, phase: .creatingJob, logger: SilentCloudConvertLogger(), label: "t",
                                            operation: { () async throws -> Int in
            if counter.increment() == 1 { throw CloudConvertError.rateLimited(retryAfter: 0.5) }
            return 42
        })
        XCTAssertEqual(value, 42)
        XCTAssertEqual(counter.value, 2)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.45, "Retry-After must be honoured")
    }

    func testOfflineDoesNotConsumeAttempts() async throws {
        let counter = Counter()
        let waits = Counter()
        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)
        let value: String = try await retrying(policy: policy, phase: .uploading, logger: SilentCloudConvertLogger(), label: "t",
                                               waitForNetwork: { _ = waits.increment() },
                                               operation: { () async throws -> String in
            if counter.increment() < 3 { throw CloudConvertError.notConnected }
            return "ok"
        })
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(waits.value, 2)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }
}

// MARK: - Credentials

final class AuthorizationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct StoreDown: Error {}

    func testRequestsThatNeedTheKeyTogetherShareOneFetch() async throws {
        let fetches = Counter()
        let authorization = RefreshableTokenAuthorization {
            _ = fetches.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return "key"
        }
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<5 { group.addTask { try await authorization.authorizationHeaderValue() } }
            for try await value in group { XCTAssertEqual(value, "Bearer key") }
        }
        XCTAssertEqual(fetches.count, 1)
    }

    func testA401WithAReplacedKeyDoesNotFetchAgain() async throws {
        let fetches = Counter()
        let authorization = RefreshableTokenAuthorization { "key-\(fetches.increment())" }
        _ = try await authorization.authorizationHeaderValue()
        // Refused with the current key: fetch a new one.
        let retryWithNewKey = await authorization.handleUnauthorized(rejected: "Bearer key-1")
        XCTAssertTrue(retryWithNewKey)
        let refreshed = try await authorization.authorizationHeaderValue()
        XCTAssertEqual(refreshed, "Bearer key-2")
        // A request that went out with the old key comes back 401 too: keep the new one.
        let retryWithKeptKey = await authorization.handleUnauthorized(rejected: "Bearer key-1")
        XCTAssertTrue(retryWithKeptKey)
        let kept = try await authorization.authorizationHeaderValue()
        XCTAssertEqual(kept, "Bearer key-2")
        XCTAssertEqual(fetches.count, 2)
    }

    func testAFailedFetchIsReportedAgainWithoutFetchingDuringTheCooldown() async {
        let fetches = Counter()
        let authorization = RefreshableTokenAuthorization(failureCooldown: 60) {
            _ = fetches.increment()
            throw StoreDown()
        }
        for _ in 0..<3 { _ = try? await authorization.authorizationHeaderValue() }
        XCTAssertEqual(fetches.count, 1)
    }

    func testAKeyStoreFailureIsAuthorizationFailedAndNotRetried() async throws {
        let fetches = Counter()
        var configuration = CloudConvertConfiguration.testing()
        configuration.authorizationProvider = RefreshableTokenAuthorization(failureCooldown: 0) {
            _ = fetches.increment()
            throw StoreDown()
        }
        let transport = StubTransport()
        let api = CloudConvertAPI(configuration: configuration, transport: transport, connectivity: AlwaysOnline())

        do {
            _ = try await api.getJob(id: "job")
            XCTFail("expected a failure")
        } catch let error as CloudConvertError {
            guard case .authorizationFailed = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(error.category, .account)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(transport.requests, 0)
    }

    func testA401FetchesTheKeyAgainAndRetriesOnce() async throws {
        let fetches = Counter()
        var configuration = CloudConvertConfiguration.testing()
        configuration.authorizationProvider = RefreshableTokenAuthorization { "key-\(fetches.increment())" }
        let transport = ScriptedTransport()
        transport.jobBody = try Fixtures.data("job-finished")
        transport.unauthorizedGets = 1
        let api = CloudConvertAPI(configuration: configuration, transport: transport, connectivity: AlwaysOnline())

        _ = try await api.getJob(id: "job-1")
        XCTAssertEqual(transport.authorizations, ["Bearer key-1", "Bearer key-2"])
        XCTAssertEqual(fetches.count, 2)
    }

    func testTheUserAgentNamesTheKitAndItsVersion() async throws {
        let transport = ScriptedTransport()
        transport.jobBody = try Fixtures.data("job-finished")
        let api = CloudConvertAPI(configuration: .testing(), transport: transport, connectivity: AlwaysOnline())
        _ = try await api.getJob(id: "job-1")
        XCTAssertTrue(transport.userAgents.first??.contains("CloudConvertKit/\(CloudConvertKitInfo.version)") == true,
                      "\(String(describing: transport.userAgents.first))")
    }

    func testFetchingKeyConfigurationDerivesItsIdentifiers() {
        let configuration = CloudConvertConfiguration.fetchingKey { "key" }
        XCTAssertEqual(configuration.environment, .production)
        XCTAssertTrue(configuration.authorizationProvider is RefreshableTokenAuthorization)
        XCTAssertTrue(configuration.backgroundSessionIdentifier.hasSuffix(".cloudconvert"))
    }

    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock { count += 1 }
            return HTTPResponse(status: 200, headers: [:], body: Data())
        }
    }
}

// MARK: - Cancellation shield

final class CancellationShieldTests: XCTestCase {

    func testReturnsValueWhenNotCancelled() async throws {
        let value = try await CancellationShield.run({ 42 }, onAbandoned: { _ in XCTFail("not abandoned") })
        XCTAssertEqual(value, 42)
    }

    func testPropagatesErrors() async {
        do {
            _ = try await CancellationShield.run({ () async throws -> Int in throw CloudConvertError.notConnected },
                                                 onAbandoned: { _ in })
            XCTFail("expected error")
        } catch {
            guard case CloudConvertError.notConnected = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAlreadyCancelledCallerNeverStartsTheOperation() async {
        let started = Flag()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CancellationShield.run({ started.set(); return 1 }, onAbandoned: { _ in })
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            guard case CloudConvertError.cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(started.isSet)
    }

    func testCancelledCallerHandsTheLateValueToCleanup() async {
        let gate = Gate()
        let abandoned = Flag()
        let task = Task {
            try await CancellationShield.run({ try await gate.wait(); return 7 }, onAbandoned: { value in
                XCTAssertEqual(value, 7); abandoned.set()
            })
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {}
        XCTAssertFalse(abandoned.isSet)
        gate.open()
        let deadline = Date().addingTimeInterval(2)
        while !abandoned.isSet && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(abandoned.isSet)
    }
}

// MARK: - Connectivity

final class ConnectivityMonitorTests: XCTestCase {

    /// Each path reading hops onto the actor in its own task, so a newer one
    /// can land first. The older one must not overwrite it, or the monitor
    /// reports offline, and refuses every request, while the device is online.
    func testAnOlderPathReadingDoesNotOverwriteANewerOne() async {
        let monitor = ConnectivityMonitor()
        await monitor.update(1_000_001, connected: true, expensive: false)
        await monitor.update(1_000_000, connected: false, expensive: false)
        let connected = await monitor.isConnected
        XCTAssertTrue(connected)
    }

    func testOnlyAnUnsatisfiedPathIsOffline() {
        XCTAssertTrue(ConnectivityMonitor.isUsable(.satisfied))
        XCTAssertTrue(ConnectivityMonitor.isUsable(.requiresConnection), "an on-demand VPN comes up when a request is made")
        XCTAssertFalse(ConnectivityMonitor.isUsable(.unsatisfied))
    }
}
