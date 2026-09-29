//  Randomised end-to-end stress test. Many conversions run at once against a
//  simulated CloudConvert that tracks every job separately (the real models
//  decode its JSON), with seeded faults at every layer: failed and ambiguous
//  job creation, upload 5xx, uploads whose response is lost, single-use upload
//  forms, poll errors, undecodable responses, purged jobs, task failures,
//  failed downloads, and cancellation at random moments.
//
//  Afterwards it checks invariants that must hold whatever happened:
//  every conversion ends exactly once, nothing is reported after the end,
//  no conversion is billed twice, deterministic failures are tried once,
//  every job the engine knows about is deleted, and no local state is left.
//
//  Reproduce a run with CCK_STRESS_SEED=<seed>; scale with CCK_STRESS_COUNT.
//

import XCTest
@testable import CloudConvertKit

// MARK: - Deterministic randomness

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class Dice: @unchecked Sendable {
    private let lock = NSLock()
    private var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }
    func chance(_ p: Double) -> Bool { lock.lock(); defer { lock.unlock() }; return Double.random(in: 0..<1, using: &rng) < p }
    func int(_ range: ClosedRange<Int>) -> Int { lock.lock(); defer { lock.unlock() }; return Int.random(in: range, using: &rng) }
    func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}

// MARK: - Simulated CloudConvert

/// What a job does once its input has arrived.
enum JobFate: String, CaseIterable {
    case finish              // converts, billed
    case conversionFailed    // engine cannot convert: `code: null`
    case transientFailure    // `code: TIMEOUT`, worth a new job
    case undecodable         // every poll returns something unparseable
    case serverDown          // every poll returns 503
    case purged              // the job disappears (404)
}

final class ChaosCloud: CloudConvertAPIClient, @unchecked Sendable {

    struct Job {
        let id: String
        let tag: String
        let specification: JobSpecification
        let fate: JobFate
        var responseLost: Bool          // created, but the client never learnt the id
        var uploadsReceived = 0
        var extraUploadsRejected = 0
        var polls = 0
        var deleted = false
        var billed = false
    }

    private let lock = NSLock()
    private let dice: Dice
    /// Fates per conversion tag, one per job attempt (the last repeats).
    private var plans: [String: [JobFate]] = [:]
    private var attempts: [String: Int] = [:]
    private(set) var jobs: [String: Job] = [:]
    private var nextID = 0

    init(dice: Dice) { self.dice = dice }

    func plan(tag: String, fates: [JobFate]) { lock.lock(); plans[tag] = fates; lock.unlock() }
    var snapshot: [Job] { lock.lock(); defer { lock.unlock() }; return Array(jobs.values) }

    private func latency() async { try? await Task.sleep(nanoseconds: UInt64(dice.int(0...3)) * 1_000_000) }

    // Jobs

    func createJob(_ specification: JobSpecification) async throws -> CCJob {
        await latency()
        try Task.checkCancellation()
        if dice.chance(0.04) { throw CloudConvertError.notConnected }          // never sent
        let lose = dice.chance(0.03)                                           // created, response lost
        lock.lock()
        nextID += 1
        let id = "job-\(nextID)"
        let tag = specification.tag ?? "-"
        let attempt = attempts[tag, default: 0]
        attempts[tag] = attempt + 1
        let fates = plans[tag] ?? [.finish]
        let fate = fates[min(attempt, fates.count - 1)]
        jobs[id] = Job(id: id, tag: tag, specification: specification, fate: fate, responseLost: lose)
        let json = jsonLocked(id)
        lock.unlock()
        if lose { throw CloudConvertError.timedOut(phase: .creatingJob) }
        return try decode(json)
    }

    func getJob(id: String) async throws -> CCJob {
        await latency()
        lock.lock()
        guard var job = jobs[id], !job.deleted else { lock.unlock(); throw CloudConvertError.notFound(nil) }
        let arrived = job.uploadsReceived > 0
        if arrived { job.polls += 1 }
        jobs[id] = job
        let transient = dice.chance(0.04)
        let json = jsonLocked(id)
        lock.unlock()
        if transient { throw CloudConvertError.serverError(status: 502, nil) }
        if arrived {
            switch job.fate {
            case .undecodable: throw CloudConvertError.decoding(reason: "getJob: not JSON")
            case .serverDown: throw CloudConvertError.serverError(status: 503, nil)
            case .purged: throw CloudConvertError.notFound(nil)
            default: break
            }
        }
        return try decode(json)
    }

    func deleteJob(id: String) async throws {
        lock.lock(); jobs[id]?.deleted = true; lock.unlock()
    }

    // Storage (called by ChaosTransfers)

    /// Returns the HTTP status storage answers for an upload to this job's form.
    func receiveUpload(jobID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[jobID], !job.deleted else { return 403 }
        if job.uploadsReceived > 0 {
            job.extraUploadsRejected += 1       // the form accepts one file
            jobs[jobID] = job
            return 400
        }
        job.uploadsReceived = 1
        if job.fate == .finish { job.billed = true }
        jobs[jobID] = job
        return 201
    }

    func canDownload(jobID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return jobs[jobID].map { !$0.deleted } ?? false
    }

    // JSON as the real API shapes it

    private func jsonLocked(_ id: String) -> Data {
        let job = jobs[id]!
        let arrived = job.uploadsReceived > 0
        let done = arrived && job.polls >= 2
        let status: String
        switch (arrived, done, job.fate) {
        case (false, _, _): status = "waiting"
        case (true, false, _): status = "processing"
        case (true, true, .finish): status = "finished"
        case (true, true, _): status = "error"
        }
        var tasks: [[String: Any]] = []
        for task in job.specification.tasks {
            var object: [String: Any] = ["id": "\(id)-\(task.name)", "name": task.name, "operation": task.operation,
                                         "job_id": id, "code": NSNull(), "message": NSNull(), "credits": NSNull()]
            if task.isImport {
                if arrived {
                    object["status"] = "finished"
                    object["result"] = ["files": [["filename": "input.bin", "size": 1024]]]
                } else {
                    object["status"] = "waiting"
                    object["result"] = ["form": ["url": "https://upload.example/\(id)/\(task.name)",
                                                 "parameters": ["expires": Int(Date().timeIntervalSince1970) + 3600,
                                                                "max_file_count": 1, "signature": "s"]]]
                }
            } else if task.isExport {
                object["status"] = status == "finished" ? "finished" : (status == "error" ? "error" : "waiting")
                if status == "finished" {
                    object["result"] = ["files": [["filename": "out.pdf", "size": 9, "url": "https://storage.example/\(id)/out.pdf"]]]
                } else if status == "error" {
                    object["code"] = "INPUT_TASK_FAILED"
                }
            } else {
                object["status"] = status == "waiting" ? "waiting" : status
                object["percent"] = done ? 100 : 40
                if status == "finished" {
                    object["credits"] = 1
                    object["result"] = ["files": [["filename": "out.pdf", "size": 9]]]
                } else if status == "error" {
                    object["code"] = job.fate == .transientFailure ? "TIMEOUT" : NSNull()
                    object["message"] = "Conversion failed"
                }
            }
            tasks.append(object)
        }
        let body: [String: Any] = ["data": ["id": id, "tag": job.tag, "status": status, "tasks": tasks,
                                            "created_at": "2026-09-29T15:51:19+00:00"]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func decode(_ data: Data) throws -> CCJob {
        try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: data).data
    }

    // Unused by the engine
    func listJobs(_ filter: JobsFilter) async throws -> CCPage<CCJob> { CCPage(data: [], meta: nil) }
    func getTask(id: String) async throws -> CCTask { throw CloudConvertError.notFound(nil) }
    func retryTask(id: String) async throws -> CCTask { throw CloudConvertError.notFound(nil) }
    func cancelTask(id: String) async throws -> CCTask { throw CloudConvertError.notFound(nil) }
    func deleteTask(id: String) async throws {}
    func operations(filter: OperationsFilter) async throws -> [CCOperation] { [] }
    func convertFormats(filter: OperationsFilter) async throws -> [CCOperation] { [] }
    func currentUser() async throws -> CCUser { throw CloudConvertError.notFound(nil) }
}

final class ChaosTransfers: FileTransferring, @unchecked Sendable {
    private let cloud: ChaosCloud
    private let dice: Dice

    init(cloud: ChaosCloud, dice: Dice) { self.cloud = cloud; self.dice = dice }

    private func jobID(_ request: URLRequest) -> String { request.url!.pathComponents[1] }

    func upload(id: String, request: URLRequest, bodyFile: URL,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await Task.sleep(nanoseconds: UInt64(dice.int(0...8)) * 1_000_000)
        progress(TransferProgress(completedBytes: 512, totalBytes: 1024))
        if dice.chance(0.05) { return outcome(503) }
        let status = cloud.receiveUpload(jobID: jobID(request))
        if status == 201, dice.chance(0.05) { throw URLError(.timedOut) }      // arrived, response lost
        progress(TransferProgress(completedBytes: 1024, totalBytes: 1024))
        return outcome(status)
    }

    func download(id: String, request: URLRequest, destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await Task.sleep(nanoseconds: UInt64(dice.int(0...5)) * 1_000_000)
        guard cloud.canDownload(jobID: jobID(request)) else { return outcome(404) }
        if dice.chance(0.05) { return outcome(500) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("converted".utf8).write(to: destination)
        progress(TransferProgress(completedBytes: 9, totalBytes: 9))
        return TransferOutcome(status: 200, responseBody: nil, fileURL: destination, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
    }

    func awaitExistingTransfer(id: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        throw CloudConvertError.transferLost(id: id)
    }
    func cancel(id: String) {}
    func forget(id: String) {}

    private func outcome(_ status: Int) -> TransferOutcome {
        TransferOutcome(status: status, responseBody: nil, fileURL: nil, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
    }
}

// MARK: - The test

final class StressTests: XCTestCase {

    private struct Outcome {
        let tag: String
        let fates: [JobFate]
        let cancelled: Bool
        let result: Result<ConversionResult, Error>
        let stages: [ConversionProgress.Stage]
    }

    func testRandomisedEndToEndInvariants() async throws {
        let env = ProcessInfo.processInfo.environment
        let seed = env["CCK_STRESS_SEED"].flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970 * 1000)
        let count = env["CCK_STRESS_COUNT"].flatMap(Int.init) ?? 150
        print("StressTests seed=\(seed) count=\(count)")
        let dice = Dice(seed: seed)

        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        defer { [work, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        var configuration = CloudConvertConfiguration.testing(workingDirectory: work, outputDirectory: out)
        configuration.polling = PollingPolicy(initialInterval: 0.002, maxInterval: 0.005, multiplier: 1.5,
                                              jobTimeout: 20, maxConsecutiveFailures: 3)
        configuration.jobRetryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: 0.002, maxDelay: 0.005, jitter: 0)
        configuration.uploadRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.002, maxDelay: 0.005, jitter: 0)
        configuration.downloadRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.002, maxDelay: 0.005, jitter: 0)
        let cloud = ChaosCloud(dice: dice)
        let engine = ConversionEngine(configuration: configuration, api: cloud,
                                      transfers: ChaosTransfers(cloud: cloud, dice: dice), connectivity: AlwaysOnline())
        let inputs = TestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: inputs) }

        // Mostly successes, with every kind of failure well represented.
        let weighted: [JobFate] = [.finish, .finish, .finish, .finish, .conversionFailed, .transientFailure,
                                   .undecodable, .serverDown, .purged]

        let outcomes = try await withThrowingTaskGroup(of: Outcome.self) { group -> [Outcome] in
            for index in 0..<count {
                let tag = "c\(index)"
                let fates = [dice.pick(weighted), dice.pick(weighted)]
                cloud.plan(tag: tag, fates: fates)
                let cancelAfter: UInt64? = dice.chance(0.25) ? UInt64(dice.int(0...40)) * 1_000_000 : nil
                // Same file name for every input, in a directory per conversion.
                let directory = inputs.appendingPathComponent(tag, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = try TestFiles.makeFile(named: "book.epub", bytes: 256 + index, in: directory)
                var builder = JobBuilder(tag: tag)
                let input = builder.importUpload(InputFile(url: file))
                builder.exportURL(builder.convert(input, to: "pdf"))
                let specification = try builder.build()

                group.addTask {
                    let log = StageLog()
                    let task = Task { try await engine.run(specification, progress: { log.append($0.stage) }) }
                    if let cancelAfter {
                        try? await Task.sleep(nanoseconds: cancelAfter)
                        task.cancel()
                    }
                    let result = await withTimeout(seconds: 60) { await task.result }
                    guard let result else {
                        XCTFail("conversion \(tag) never finished (seed \(seed))")
                        return Outcome(tag: tag, fates: fates, cancelled: cancelAfter != nil,
                                       result: .failure(CloudConvertError.jobTimedOut(jobID: "hang")), stages: log.snapshot)
                    }
                    return Outcome(tag: tag, fates: fates, cancelled: cancelAfter != nil, result: result, stages: log.snapshot)
                }
            }
            var all: [Outcome] = []
            for try await outcome in group { all.append(outcome) }
            return all
        }

        // Let detached remote deletions and late shielded creations settle.
        try await Task.sleep(nanoseconds: 300_000_000)
        let jobs = cloud.snapshot
        let jobsByTag = Dictionary(grouping: jobs, by: \.tag)
        var tally: [String: Int] = [:]

        for outcome in outcomes {
            let context = "\(outcome.tag) fates=\(outcome.fates.map(\.rawValue)) cancelled=\(outcome.cancelled) seed=\(seed)"
            let mine = jobsByTag[outcome.tag] ?? []

            // 1. Exactly one terminal stage, and nothing after it.
            let terminals = outcome.stages.filter(\.isTerminal)
            XCTAssertEqual(terminals.count, 1, "terminal stages \(terminals): \(context)")
            XCTAssertTrue(outcome.stages.last?.isTerminal ?? false, "last stage \(String(describing: outcome.stages.last)): \(context)")

            // 2. Never billed twice; never more jobs than the retry policy allows
            //    (plus ones whose create response was lost, which never ran).
            XCTAssertLessThanOrEqual(mine.filter(\.billed).count, 1, "billed twice: \(context)")
            XCTAssertLessThanOrEqual(mine.filter { !$0.responseLost }.count, configuration.jobRetryPolicy.maxAttempts, context)

            // 3. A job whose create response was lost is never used.
            XCTAssertTrue(mine.filter(\.responseLost).allSatisfy { $0.uploadsReceived == 0 }, context)

            // 4. Once an input reached a job that can't succeed (corrupt file,
            //    unreadable responses), no further job is started for it.
            let ordered = mine.sorted { Int($0.id.dropFirst(4))! < Int($1.id.dropFirst(4))! }
            if let dead = ordered.firstIndex(where: { $0.uploadsReceived > 0 && [.conversionFailed, .undecodable].contains($0.fate) }) {
                XCTAssertEqual(dead, ordered.count - 1, "rebuilt after a deterministic failure: \(context)")
            }

            // 5. The outcome matches what happened.
            switch outcome.result {
            case .success(let result):
                XCTAssertEqual(outcome.stages.last, .completed, context)
                XCTAssertTrue(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, context)
                XCTAssertEqual(mine.filter(\.billed).count, 1, "succeeded without a converted job: \(context)")
                tally["completed", default: 0] += 1
            case .failure(let error):
                let ccError = error as? CloudConvertError
                XCTAssertNotNil(ccError, "not a CloudConvertError: \(error) \(context)")
                if ccError?.isCancellation == true {
                    XCTAssertEqual(outcome.stages.last, .cancelled, context)
                    tally["cancelled", default: 0] += 1
                } else {
                    XCTAssertEqual(outcome.stages.last, .failed, context)
                    tally["failed:\(ccError?.analyticsCode ?? "?")", default: 0] += 1
                }
            }
        }

        // 6. Every job the engine learnt about is deleted from CloudConvert.
        let leaked = jobs.filter { !$0.responseLost && !$0.deleted }
        XCTAssertTrue(leaked.isEmpty, "jobs left on CloudConvert: \(leaked.map { "\($0.id)(\($0.tag))" }) seed=\(seed)")

        // 7. No local state left behind.
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "records left: \(pending.map(\.id))")
        let storage = FileStorage(workingDirectory: work, outputDirectory: out, diskSpaceSafetyMargin: 0)
        for directory in [storage.stagingDirectory, storage.bodiesDirectory, storage.downloadsDirectory] {
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            XCTAssertTrue(leftovers.isEmpty, "\(directory.lastPathComponent) not cleaned: \(leftovers.prefix(5))")
        }
        let outputs = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertEqual(outputs.count, tally["completed", default: 0], "one output file per completed conversion")

        let extraUploads = jobs.map(\.extraUploadsRejected).reduce(0, +)
        print("StressTests seed=\(seed): jobs=\(jobs.count) orphaned(response lost)=\(jobs.filter(\.responseLost).count) " +
              "re-uploads rejected=\(extraUploads) outcomes=\(tally.sorted { $0.key < $1.key })")
        XCTAssertEqual(extraUploads, 0, "an upload was repeated to a form that already had its file")
    }
}

/// `nil` when `body` does not finish within `seconds`.
func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
