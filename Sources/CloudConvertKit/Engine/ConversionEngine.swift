//  The orchestrator. One call — `convert(_:progress:)` — takes a request
//  through: validate → stage input → create job → upload → poll → download →
//  finalize, with retries at every layer, offline suspension, cancellation,
//  crash-safe persistence and cleanup of both local and remote artefacts.
//
//  Nothing here talks to URLSession directly; the API client and the transfer
//  manager are injected so the whole pipeline can be exercised in tests.
//  Nothing here knows about UI: progress is delivered through a `@Sendable`
//  handler / `AsyncStream` and the app decides how to present it.
//

import Foundation

public final class ConversionEngine: @unchecked Sendable {

    public let configuration: CloudConvertConfiguration

    private let api: any CloudConvertAPIClient
    private let transfers: any FileTransferring
    private let connectivity: any ConnectivityMonitoring
    private let store: any ConversionRecordStoring
    private let storage: FileStorage
    private let logger: any CloudConvertLogging

    /// Conversions this process is running right now. They are persisted like
    /// everything else, but must never be reported as "pending from a previous
    /// launch" or resumed a second time.
    private let active = ActiveConversions()

    /// The conversions `resumePendingConversions` started, for `resumedConversion(id:)`.
    private let resumed = ResumedConversions()

    /// Records older than this are considered unrecoverable on resume; the
    /// server purges jobs after 24 h and upload forms expire long before.
    private let maxResumableAge: TimeInterval = 20 * 60 * 60

    /// - Parameters:
    ///   - api: Injected in tests. Defaults to `CloudConvertAPI` over URLSession.
    ///   - transfers: Injected in tests. Defaults to the `BackgroundTransferManager`
    ///     for `configuration.backgroundSessionIdentifier`, reusing an existing one
    ///     (a background session identifier must only ever be created once per
    ///     process, so engines created at the same time share one).
    public init(configuration: CloudConvertConfiguration,
                api: (any CloudConvertAPIClient)? = nil,
                transfers: (any FileTransferring)? = nil,
                connectivity: any ConnectivityMonitoring = ConnectivityMonitor.shared,
                store: (any ConversionRecordStoring)? = nil) {
        let storage = FileStorage(workingDirectory: configuration.workingDirectory,
                                  outputDirectory: configuration.outputDirectory,
                                  diskSpaceSafetyMargin: configuration.diskSpaceSafetyMargin)
        self.configuration = configuration
        self.logger = configuration.logger
        self.connectivity = connectivity
        self.storage = storage
        self.api = api ?? CloudConvertAPI(configuration: configuration, connectivity: connectivity)
        self.transfers = transfers ?? BackgroundTransferManager.shared(for: configuration.backgroundSessionIdentifier) {
            BackgroundTransferManager(identifier: configuration.backgroundSessionIdentifier,
                                      registryDirectory: configuration.workingDirectory,
                                      usesBackgroundSession: configuration.usesBackgroundTransfers,
                                      allowsCellularAccess: configuration.allowsCellularTransfers,
                                      resourceTimeout: configuration.transferResourceTimeout,
                                      logger: configuration.logger)
        }
        self.store = store ?? ConversionRecordStore(directory: storage.recordsDirectory, logger: configuration.logger)
        try? storage.prepareDirectories()
        storage.purgeStaleTemporaryFiles()
    }

    // MARK: - Public API: running conversions

    /// Runs a conversion to completion. Cancel by cancelling the calling task.
    /// `progress` is called on arbitrary threads.
    ///
    /// A conversion that stops because the network or the polling deadline
    /// ran out while its job may still finish throws an error that
    /// `isResumable`: it is kept, and `resumePendingConversions` continues it.
    public func convert(_ request: ConversionRequest,
                        conversionID: String? = nil,
                        progress: ConversionProgressHandler? = nil) async throws -> ConversionResult {
        let specification = try request.makeJobSpecification(defaultTag: configuration.jobTag,
                                                              defaultTimeout: configuration.serverTaskTimeout)
        return try await run(specification, output: request.output, userInfo: request.userInfo,
                             conversionID: conversionID, progress: progress)
    }

    /// Runs a hand-built job (see `JobBuilder`).
    public func run(_ specification: JobSpecification,
                    output: OutputOptions = .default,
                    userInfo: [String: String] = [:],
                    conversionID: String? = nil,
                    progress: ConversionProgressHandler? = nil) async throws -> ConversionResult {
        let conversionID = conversionID ?? UUID().uuidString
        let reporter = ProgressReporter(conversionID: conversionID, weights: configuration.progressWeights, handler: progress)
        active.insert(conversionID)
        defer { active.remove(conversionID) }
        reporter.stage(.preparing)

        // Everything before the record exists fails locally and cheaply.
        let record: ConversionRecord
        do {
            record = try await prepare(specification, output: output, userInfo: userInfo, conversionID: conversionID)
        } catch {
            let ccError = CloudConvertError.wrap(error, phase: .preparing)
            reporter.stage(ccError.isCancellation ? .cancelled : .failed)
            storage.cleanup(conversionID: conversionID)
            await store.delete(id: conversionID)
            throw ccError
        }
        return try await execute(record, reporter: reporter)
    }

    /// Starts a conversion and returns immediately with a handle that exposes
    /// a progress stream and the eventual result.
    public func start(_ request: ConversionRequest) -> ConversionHandle {
        launch { [self] id, progress in
            try await convert(request, conversionID: id, progress: progress)
        }
    }

    /// Starts a hand-built job and returns a handle.
    public func start(_ specification: JobSpecification,
                      output: OutputOptions = .default,
                      userInfo: [String: String] = [:]) -> ConversionHandle {
        launch { [self] id, progress in
            try await run(specification, output: output, userInfo: userInfo, conversionID: id, progress: progress)
        }
    }

    private func launch(
        _ body: @escaping @Sendable (_ conversionID: String, _ progress: @escaping ConversionProgressHandler) async throws -> ConversionResult
    ) -> ConversionHandle {
        let conversionID = UUID().uuidString
        let (stream, continuation) = ConversionEngine.makeProgressStream()
        let task = Task<ConversionResult, Error> {
            defer { continuation.finish() }
            return try await body(conversionID) { continuation.yield($0) }
        }
        return ConversionHandle(id: conversionID, progress: stream, task: task)
    }

    static func makeProgressStream() -> (AsyncStream<ConversionProgress>, AsyncStream<ConversionProgress>.Continuation) {
        var continuation: AsyncStream<ConversionProgress>.Continuation!
        let stream = AsyncStream<ConversionProgress>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        return (stream, continuation)
    }

    // MARK: - Public API: pending conversions from a previous launch

    /// Conversions persisted by a previous launch that never completed, and
    /// conversions that stopped with an error that `isResumable`.
    /// Conversions running in this process are excluded.
    public func pendingConversions() async -> [ConversionRecord] {
        let activeIDs = active.snapshot
        return await store.all().filter { !activeIDs.contains($0.id) }
    }

    /// Resumes every pending conversion. Call once at launch after the
    /// background session has been set up, and after an error that
    /// `isResumable`, for example when the device is back online. Records
    /// that are too old, or whose staged inputs vanished, are cleaned up and
    /// reported as failures through the returned handles. Calling it twice
    /// never runs a record twice.
    public func resumePendingConversions() async -> [ConversionHandle] {
        await resumePendingConversions { _ in true }
    }

    /// Resumes the pending conversions `isIncluded` accepts: say, those your
    /// own layer started (recognised by `userInfo`), or the one that just
    /// stopped with a resumable error (by `id`). Every other record is left
    /// as it is: not started, not marked as running, still pending.
    public func resumePendingConversions(where isIncluded: @Sendable (ConversionRecord) -> Bool) async -> [ConversionHandle] {
        var handles: [ConversionHandle] = []
        for listed in await store.all() where isIncluded(listed) {
            guard active.insertIfAbsent(listed.id) else { continue }
            // Claimed, so nothing else runs it now. It may have finished since
            // the list was read, though, or stopped again further on.
            guard let record = await store.load(id: listed.id), isIncluded(record) else {
                active.remove(listed.id)
                continue
            }
            handles.append(resumed.start(record.id) { [self] progress in
                defer { active.remove(record.id) }
                let reporter = ProgressReporter(conversionID: record.id, weights: configuration.progressWeights) { progress.yield($0) }
                return try await resume(record, reporter: reporter)
            })
        }
        return handles
    }

    /// Another handle on a conversion that `resumePendingConversions`
    /// started in this process: its progress from the latest stage on, its
    /// result, and `cancel()`. One that stopped again with an error that
    /// `isResumable` gives that error, and is pending again. Nil when there
    /// is none, or it failed for good or was cancelled: trying it again
    /// starts it over.
    ///
    /// Something that shows a conversion the app may also have resumed
    /// itself (as `ConversionViewModel.retry(id:)` does) follows that run
    /// here instead of converting the file again.
    public func resumedConversion(id: String) -> ConversionHandle? {
        resumed.handle(id)
    }

    /// Forgets a pending conversion without running it: cancels its transfers,
    /// deletes the server job and removes local files (outputs it had already
    /// saved included) and the record.
    public func discardPendingConversion(id: String) async {
        // A conversion running in this process is stopped by cancelling its
        // handle; tearing it down here would leave that task waiting forever.
        guard !active.snapshot.contains(id) else {
            logger.warning("discardPendingConversion(\(id)): the conversion is running; cancel its handle instead")
            return
        }
        resumed.remove(id)
        if let record = await store.load(id: id) {
            abortTransfers(record)
            if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }
            removeSavedOutputs(record)
        }
        storage.cleanup(conversionID: id)
        await store.delete(id: id)
    }

    // MARK: - Public API: catalogue

    /// Queries the operations catalogue, e.g. to validate a format pair before
    /// starting a job (`filter: OperationsFilter(inputFormat: "heic", outputFormat: "jpg")`).
    public func availableOperations(_ filter: OperationsFilter = OperationsFilter()) async throws -> [CCOperation] {
        try await api.operations(filter: filter)
    }

    /// The underlying API client, for calls the engine does not wrap
    /// (`currentUser()` for the credit balance, `listJobs`, `convertFormats`…).
    public var apiClient: any CloudConvertAPIClient { api }

    // MARK: - Preparation

    private func prepare(_ specification: JobSpecification,
                         output: OutputOptions,
                         userInfo: [String: String],
                         conversionID: String) async throws -> ConversionRecord {
        try specification.validate()
        try storage.prepareDirectories()

        // Stage every input up front so a failure (missing file, too large)
        // surfaces before any credit is spent. Copying is blocking IO, so it
        // runs off the cooperative thread pool.
        let storage = self.storage
        let limit = configuration.maxInputFileSize
        var staged: [String: StagedInput] = [:]
        for (taskName, input) in specification.uploads.sorted(by: { $0.key < $1.key }) {
            staged[taskName] = try await BlockingWork.run {
                try storage.stage(input, conversionID: conversionID, taskName: taskName, limit: limit)
            }
        }
        try storage.ensureDiskSpace(forExpectedBytes: ConversionEngine.requiredFreeSpace(
            inputSizes: staged.values.map(\.size), expectedOutputBytes: output.expectedOutputBytes))

        let record = ConversionRecord(id: conversionID,
                                      specification: specification,
                                      staged: staged,
                                      output: output,
                                      userInfo: userInfo,
                                      createdAt: Date(),
                                      updatedAt: Date(),
                                      phase: .preparing,
                                      jobAttempt: 1,
                                      jobID: nil,
                                      uploadTransfers: [:],
                                      uploadedTaskNames: [],
                                      downloadTransfers: [:],
                                      exportedFiles: [])
        await store.save(record)
        return record
    }

    /// Free space a conversion still needs once its inputs are staged: room
    /// for the multipart body of the largest input while it uploads, or for
    /// the outputs while they download (each body is deleted after its
    /// upload, so never both). Without an estimate, the outputs are assumed
    /// to be twice the inputs.
    static func requiredFreeSpace(inputSizes: [Int64], expectedOutputBytes: Int64?) -> Int64 {
        max(inputSizes.max() ?? 0, expectedOutputBytes ?? inputSizes.reduce(0, +) * 2)
    }

    // MARK: - Resume

    private func resume(_ record: ConversionRecord, reporter: ProgressReporter) async throws -> ConversionResult {
        reporter.stage(.preparing, jobAttempt: record.jobAttempt, jobID: record.jobID)
        do {
            guard Date().timeIntervalSince(record.createdAt) < maxResumableAge else {
                throw CloudConvertError.jobLost(jobID: record.jobID ?? "none")
            }
            for staged in record.staged.values where !FileManager.default.fileExists(atPath: staged.stagedURL.path) {
                throw CloudConvertError.fileNotFound(staged.stagedURL)
            }
        } catch {
            let ccError = CloudConvertError.wrap(error, phase: record.phase)
            await abandon(record, reporter: reporter, stage: .failed)
            throw ccError
        }
        return try await execute(record, reporter: reporter)
    }

    // MARK: - Job-level retry loop

    /// The single place where a conversion reaches a terminal state: every
    /// exit path emits exactly one `.completed` / `.failed` / `.cancelled`
    /// stage and either cleans up local files, the record, transfers and the
    /// server job, or keeps them for a resume (`stop`).
    private func execute(_ initialRecord: ConversionRecord, reporter: ProgressReporter) async throws -> ConversionResult {
        var record = initialRecord
        let startedAt = Date()

        let activity = configuration.backgroundActivity.beginActivity(named: "CloudConvertKit.conversion.\(record.id)")
        defer { if let activity { configuration.backgroundActivity.endActivity(activity) } }

        while true {
            do {
                let result = try await runJob(&record, reporter: reporter, startedAt: startedAt)
                reporter.stage(.completed, jobID: record.jobID)
                await finishLocally(record)
                return result
            } catch {
                let ccError = CloudConvertError.wrap(error, phase: record.phase)
                logger.error("Conversion \(record.id) attempt \(record.jobAttempt) failed in \(record.phase.rawValue): \(ccError.analyticsCode)",
                             metadata: ["jobID": record.jobID ?? "-"])

                let attempt = record.jobAttempt
                guard shouldRebuildJob(after: ccError, record: record),
                      configuration.jobRetryPolicy.shouldRetry(afterAttempt: attempt) else {
                    throw await stop(record, after: ccError, reporter: reporter)
                }

                // An upload that failed client-side may still have reached
                // storage (response lost). Then the job is converting, and a
                // rebuild would convert and bill the file twice. If the server
                // can't say, the job is not rebuilt either.
                let arrived: Bool
                do {
                    arrived = try await uploadsArrived(record, after: ccError)
                } catch {
                    let checkError = CloudConvertError.wrap(error, phase: record.phase)
                    let decisive = checkError.isCancellation || keepsRecord(after: checkError, record: record)
                    throw await stop(record, after: decisive ? checkError : ccError, reporter: reporter)
                }
                if arrived {
                    logger.notice("Conversion \(record.id): the upload had arrived; continuing with job \(record.jobID ?? "-")")
                    for taskName in record.specification.uploadTaskNames where !record.uploadedTaskNames.contains(taskName) {
                        markUploaded(taskName, record: &record, reporter: reporter)
                    }
                    record.uploadTransfers = [:]
                    await store.save(record)
                    continue
                }

                // Rebuild the job from scratch (fresh upload form, fresh tasks).
                let delay = ccError.mandatoryRetryDelay ?? configuration.jobRetryPolicy.delay(forAttempt: attempt)
                abortTransfers(record)
                if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }
                record.jobAttempt = attempt + 1
                record.jobID = nil
                record.uploadTransfers = [:]
                record.uploadedTaskNames = []
                record.downloadTransfers = [:]
                record.exportedFiles = []
                record.phase = .preparing
                await store.save(record)
                reporter.resetForNewAttempt(record.jobAttempt)
                reporter.stage(.retrying(attempt: record.jobAttempt, delay: delay, scope: .job, reason: ccError.analyticsCode),
                               jobAttempt: record.jobAttempt)
                logger.notice("Conversion \(record.id): rebuilding job (attempt \(record.jobAttempt)) in \(String(format: "%.1f", delay))s")
                do {
                    try await Task.sleep(seconds: delay)
                } catch {
                    // Cancelled while waiting to rebuild: clean up like any other cancellation.
                    await abandon(record, reporter: reporter, stage: .cancelled)
                    throw CloudConvertError.cancelled
                }
            }
        }
    }

    /// Whether a failed attempt is worth a brand-new job. A rebuild uploads
    /// the input again and, if the first job already converted, is billed
    /// again, so only errors that show this job is unusable qualify:
    /// - Once downloading, never: the conversion is done and paid for.
    /// - Errors that keep the conversion for a resume (`keepsRecord`): no;
    ///   the job may be converting.
    /// - Errors that invalidated the job (expired form, purged job, lost
    ///   transfer, a transient task failure): yes.
    /// - Connectivity failures: no; the phase already waited
    ///   `offlineWaitTimeout` for the network, so a rebuild would wait again.
    /// - A response we could not parse says nothing about the job: no.
    /// - Transport errors once every input is uploaded (or a resumed job's
    ///   status could not be fetched): no; the job may be converting.
    /// - Transport errors creating the job: only when repeating `POST /jobs`
    ///   cannot start a second billed job.
    private func shouldRebuildJob(after error: CloudConvertError, record: ConversionRecord) -> Bool {
        switch record.phase {
        case .downloading, .finishing: return false
        default: break
        }
        if keepsRecord(after: error, record: record) { return false }
        if error.requiresNewJob { return true }
        if error.isConnectivityRelated { return false }
        switch error {
        case .decoding, .invalidResponse:
            return false
        default:
            break
        }
        guard error.isRetryable else { return false }
        if record.jobID != nil {
            let uploadsDone = record.specification.uploadTaskNames.allSatisfy(record.uploadedTaskNames.contains)
            return !uploadsDone && record.phase == .uploading
        }
        return record.specification.startsOnlyAfterUpload || error.provesRequestWasNotProcessed
    }

    /// Whether a conversion that stopped with `error` is kept instead of
    /// cleaned up: its job exists and may still finish, or already has, and
    /// all that ran out is the network or the time to wait for the job.
    /// Deleting that job would throw away a conversion that may be paid for.
    /// A request that timed out while online is not the network running
    /// out: it is retried, and an upload rebuilds the job, as any other.
    private func keepsRecord(after error: CloudConvertError, record: ConversionRecord) -> Bool {
        guard record.jobID != nil else { return false }
        if case .jobTimedOut = error { return true }
        return error.isConnectivityRelated
    }

    /// Ends a conversion that cannot go on, and returns the error to throw.
    /// One that `keepsRecord` is saved for `resumePendingConversions()` and
    /// ends with an error that `isResumable`; any other is cleaned up locally
    /// and remotely, and so is one cancelled meanwhile, whatever it ran into.
    private func stop(_ record: ConversionRecord, after error: CloudConvertError, reporter: ProgressReporter) async -> CloudConvertError {
        if error.isCancellation || Task.isCancelled {
            await abandon(record, reporter: reporter, stage: .cancelled)
            return .cancelled
        }
        guard keepsRecord(after: error, record: record) else {
            await abandon(record, reporter: reporter, stage: .failed)
            return error
        }
        await store.save(record)
        reporter.stage(.failed, jobID: record.jobID)
        logger.notice("Conversion \(record.id): stopped (\(error.analyticsCode)); kept with job \(record.jobID ?? "-") to resume")
        if case .jobTimedOut = error { return error }
        return .timedOut(phase: .waitingForNetwork)
    }

    /// Whether every pending upload of this job reached storage, according to
    /// the server, after an upload-phase failure that would rebuild the job.
    /// Throws when the server could not tell.
    private func uploadsArrived(_ record: ConversionRecord, after error: CloudConvertError) async throws -> Bool {
        guard record.phase == .uploading, let jobID = record.jobID, !error.requiresNewJob else { return false }
        let pending = record.specification.uploadTaskNames.filter { !record.uploadedTaskNames.contains($0) }
        guard !pending.isEmpty else { return false }
        let job: CCJob
        do {
            job = try await fetchJob(jobID)
        } catch CloudConvertError.jobLost {
            return false     // gone: nothing is converting
        }
        return pending.allSatisfy { job.task(named: $0).map { $0.status != .waiting } ?? false }
    }

    private func abandon(_ record: ConversionRecord, reporter: ProgressReporter, stage: ConversionProgress.Stage) async {
        reporter.stage(stage, jobID: record.jobID)
        abortTransfers(record)
        if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }
        removeSavedOutputs(record)
        await finishLocally(record)
    }

    // MARK: - One job attempt

    private func runJob(_ record: inout ConversionRecord, reporter: ProgressReporter, startedAt: Date) async throws -> ConversionResult {
        var finishedJob: CCJob?

        // Resuming a conversion that already reached the download phase needs
        // no server round trip: the export URLs are in the record.
        let resumingDownload = record.phase == .downloading && !record.exportedFiles.isEmpty && record.jobID != nil
        if !resumingDownload {
            // Only a job this attempt did not create can have stale upload forms.
            let resumingJob = record.jobID != nil
            let job = try await ensureJob(&record, reporter: reporter)
            try await uploadInputs(&record, job: job, formsMayBeStale: resumingJob, reporter: reporter)
            finishedJob = try await waitForJob(&record, reporter: reporter)
        }

        let files = try await downloadOutputs(&record, reporter: reporter)

        record.phase = .finishing
        reporter.stage(.finishing, jobID: record.jobID)
        if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }

        let credits = finishedJob?.tasks.compactMap(\.credits) ?? []
        return ConversionResult(conversionID: record.id,
                                jobID: record.jobID ?? finishedJob?.id ?? "",
                                files: files,
                                credits: credits.isEmpty ? nil : credits.saturatingSum(),
                                duration: Date().timeIntervalSince(startedAt),
                                userInfo: record.userInfo)
    }

    private func ensureJob(_ record: inout ConversionRecord, reporter: ProgressReporter) async throws -> CCJob {
        reporter.stage(.creatingJob, jobAttempt: record.jobAttempt)

        if let jobID = record.jobID {
            // Resuming: fetch the job to recover upload forms / status. The
            // persisted phase is kept, so a failure here is judged by how far
            // the job got (it may be converting), not as a failed creation.
            let job = try await fetchJob(jobID)
            if job.status == .error { throw failure(for: job) }
            return job
        }

        record.phase = .creatingJob
        try await waitForNetworkIfNeeded(reporter: reporter, restoreTo: .creatingJob)
        let job = try await createJobSurvivingCancellation(record.specification, conversionID: record.id)

        // Record the job before anything else can fail, so every exit path
        // (including the check below) deletes it from CloudConvert.
        record.jobID = job.id
        await store.save(record)

        // Every upload task must have come back with a form, otherwise the
        // response is unusable and we must not proceed.
        for taskName in record.specification.uploadTaskNames {
            guard job.task(named: taskName)?.result?.form != nil else {
                logger.error("Job \(job.id): upload task \(taskName) has no form in the create response")
                throw CloudConvertError.uploadFormInvalid
            }
        }
        reporter.stage(.creatingJob, jobID: job.id)
        logger.info("Conversion \(record.id): created job \(job.id)")
        return job
    }

    /// `GET /jobs/{id}`, with a 404 reported as what it means here: the job
    /// is gone (`.jobLost`, which rebuilds it).
    private func fetchJob(_ jobID: String) async throws -> CCJob {
        do {
            return try await api.getJob(id: jobID)
        } catch CloudConvertError.notFound {
            throw CloudConvertError.jobLost(jobID: jobID)
        }
    }

    /// `POST /jobs`, shielded from cancellation of the calling task.
    ///
    /// Cancelling the request client-side does not stop CloudConvert creating
    /// the job, and a job we never learnt the id of could not be deleted. So
    /// the request always runs to completion: a cancelled caller returns
    /// `.cancelled` straight away, and the job, once it exists, is deleted.
    private func createJobSurvivingCancellation(_ specification: JobSpecification, conversionID: String) async throws -> CCJob {
        let api = self.api
        let logger = self.logger
        return try await CancellationShield.run {
            try await api.createJob(specification)
        } onAbandoned: { [weak self] job in
            logger.notice("Conversion \(conversionID): cancelled while creating job \(job.id); deleting it")
            if let self {
                self.deleteRemoteJobDetached(job.id)
            } else {
                Task.detached(priority: .utility) { try? await api.deleteJob(id: job.id) }
            }
        }
    }

    private func uploadInputs(_ record: inout ConversionRecord, job: CCJob, formsMayBeStale: Bool, reporter: ProgressReporter) async throws {
        let pending = record.specification.uploadTaskNames.filter { !record.uploadedTaskNames.contains($0) }
        guard !pending.isEmpty else { return }

        record.phase = .uploading
        for taskName in record.specification.uploadTaskNames {
            if let staged = record.staged[taskName] {
                reporter.registerUpload(taskName: taskName, totalBytes: staged.size)
                if record.uploadedTaskNames.contains(taskName) { reporter.uploadFinished(taskName: taskName) }
            }
        }
        reporter.stage(.uploading, jobID: job.id)

        for taskName in pending {
            guard let staged = record.staged[taskName] else {
                throw CloudConvertError.invalidRequest(reason: "No staged file for upload task \(taskName)")
            }

            // Resume case 1: the server already has the file (the app died
            // between the upload finishing and the record being updated).
            // Any status past `waiting` means the upload arrived.
            if let serverTask = job.task(named: taskName), serverTask.status != .waiting {
                if let existingID = record.uploadTransfers[taskName] { transfers.forget(id: existingID) }
                markUploaded(taskName, record: &record, reporter: reporter)
                await store.save(record)
                continue
            }

            try await uploadOne(taskName: taskName, staged: staged, job: job, formMayBeStale: formsMayBeStale,
                                record: &record, reporter: reporter)
            markUploaded(taskName, record: &record, reporter: reporter)
            await store.save(record)
        }
    }

    private func uploadOne(taskName: String,
                           staged: StagedInput,
                           job: CCJob,
                           formMayBeStale: Bool,
                           record: inout ConversionRecord,
                           reporter: ProgressReporter) async throws {
        // Resume case 2: re-attach to the upload a previous launch started.
        // One that is gone, or failed while the app was not running, is sent
        // again. Any other result is the first attempt of the retry loop
        // below, judged exactly like a fresh upload's: a 5xx is retried
        // against the same form, a network error waits for the network.
        // Either way it may have delivered the file and lost only the
        // response, so the server is asked before the file is sent again.
        var reattachFailure: Error?
        let reattached = record.uploadTransfers[taskName] != nil
        if let existingID = record.uploadTransfers[taskName] {
            do {
                let outcome = try await transfers.awaitExistingTransfer(id: existingID) { [reporter] in
                    reporter.upload(taskName: taskName, progress: $0)
                }
                if outcome.status != nil {
                    try validateUpload(outcome)
                    transfers.forget(id: existingID)
                    return
                }
            } catch CloudConvertError.transferLost {
            } catch {
                reattachFailure = error
            }
            transfers.forget(id: existingID)
            if reattachFailure == nil { logger.notice("Conversion \(record.id): upload \(taskName) was lost; restarting it") }
            try Task.checkCancellation()
        }

        // Fresh upload: the form must exist and accept the size. A form a
        // previous launch received may also have expired, but the device
        // clock can be wrong: it only decides while a new job is still
        // allowed, and otherwise storage judges the form.
        guard let form = job.task(named: taskName)?.result?.form else {
            throw CloudConvertError.uploadFormInvalid
        }
        if formMayBeStale, form.isExpired, configuration.jobRetryPolicy.shouldRetry(afterAttempt: record.jobAttempt) {
            if reattached, let jobID = record.jobID, try await uploadArrived(taskName, jobID: jobID) { return }
            throw CloudConvertError.uploadFormExpired
        }
        if let limit = form.maxFileSize, staged.size > limit {
            throw CloudConvertError.fileTooLarge(staged.original.url, size: staged.size, limit: limit)
        }

        let bodyDirectory = storage.bodiesDirectory.appendingPathComponent(record.id, isDirectory: true)
        try storage.ensureDirectory(bodyDirectory)
        let bodyURL = bodyDirectory.appendingPathComponent("\(taskName).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        // Writing the body copies the whole file: blocking IO, off the pool.
        let mimeType = MultipartFormWriter.mimeType(forExtension: (staged.filename as NSString).pathExtension)
        let body = try await BlockingWork.runCancellable { isCancelled in
            try MultipartFormWriter.writeUploadBody(form: form,
                                                    file: staged.stagedURL,
                                                    filename: staged.filename,
                                                    mimeType: mimeType,
                                                    to: bodyURL,
                                                    isCancelled: isCancelled)
        }

        // URLSession derives Content-Length from the file itself.
        let request: URLRequest = {
            var request = URLRequest(url: form.url)
            request.httpMethod = "POST"
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            return request
        }()

        let conversionID = record.id
        let jobID = record.jobID
        let attemptBase = record.jobAttempt
        let uploadAttempt = Counter()
        let transfers = self.transfers
        let waitForNetwork = makeNetworkWaiter(reporter: reporter, restoreTo: .uploading)
        let firstFailure = reattachFailure

        // Each HTTP attempt gets its own transfer id; the record always points
        // at the most recent one so a relaunch can re-attach to it.
        let recordBox = RecordBox(record)
        let store = self.store
        let logger = self.logger
        defer { record = recordBox.value }
        try await retrying(policy: configuration.uploadRetryPolicy, phase: .uploading, logger: logger,
                           label: "upload \(taskName)", waitForNetwork: waitForNetwork,
                           // A job that is gone needs a new job, not another upload.
                           isSafeToRepeat: { if case .jobLost = $0 { return false }; return true },
                           onRetry: { attempt, delay, error in
            reporter.stage(.retrying(attempt: attempt, delay: delay, scope: .phase(.uploading), reason: error.analyticsCode), jobID: jobID)
        },
                           operation: { () async throws -> Void in
            reporter.stage(.uploading, jobID: jobID)
            let attempt = uploadAttempt.increment()
            if attempt == 1, let firstFailure { throw firstFailure }
            // A previous attempt may have reached storage although its
            // response was lost. The form accepts one file, so a second upload
            // would be rejected and rebuild the job; ask the server first.
            // A failed check is retried by this loop like a failed upload.
            if attempt > 1 || reattached, let jobID, try await self.uploadArrived(taskName, jobID: jobID) {
                logger.notice("Conversion \(conversionID): upload \(taskName) had already arrived")
                return
            }
            let transferID = "\(conversionID)-up-\(taskName)-a\(attemptBase)-\(attempt)"
            recordBox.update { $0.uploadTransfers[taskName] = transferID }
            await store.save(recordBox.value)

            let outcome = try await transfers.upload(id: transferID, request: request, bodyFile: body.fileURL) { [reporter] in
                reporter.upload(taskName: taskName, progress: $0)
            }
            transfers.forget(id: transferID)
            try self.validateUpload(outcome)
        })
    }

    /// Whether storage has the file for `taskName`: the task leaves
    /// `waiting` once its upload arrives.
    private func uploadArrived(_ taskName: String, jobID: String) async throws -> Bool {
        try await fetchJob(jobID).task(named: taskName).map { $0.status != .waiting } ?? false
    }

    private func validateUpload(_ outcome: TransferOutcome) throws {
        guard let status = outcome.status else {
            throw CloudConvertError.network(code: .unknown, description: outcome.errorDescription ?? "No response from upload endpoint")
        }
        guard (200...299).contains(status) else {
            let snippet = outcome.responseBody.flatMap { String(data: $0.prefix(512), encoding: .utf8) }
            logger.error("Upload rejected with \(status)", metadata: ["body": snippet ?? "<no body>"])
            throw CloudConvertError.uploadRejected(status: status, body: snippet)
        }
    }

    private func markUploaded(_ taskName: String, record: inout ConversionRecord, reporter: ProgressReporter) {
        if !record.uploadedTaskNames.contains(taskName) { record.uploadedTaskNames.append(taskName) }
        record.uploadTransfers.removeValue(forKey: taskName)
        reporter.uploadFinished(taskName: taskName)
        logger.info("Conversion \(record.id): uploaded \(taskName)")
    }

    private func waitForJob(_ record: inout ConversionRecord, reporter: ProgressReporter) async throws -> CCJob {
        guard let jobID = record.jobID else { throw CloudConvertError.invalidResponse(reason: "Missing job id") }
        record.phase = .processing
        await store.save(record)

        let processingStart = Date()
        let expected = ProcessingProgressEstimator.expectedDuration(inputBytes: record.totalInputBytes,
                                                                    outputFormat: record.outputFormatHint)
        let processingTaskNames = record.specification.processingTaskNames
        reporter.processing(fraction: 0, jobID: jobID)

        let poller = JobPoller(api: api,
                               policy: configuration.polling,
                               connectivity: connectivity,
                               offlineWaitTimeout: configuration.offlineWaitTimeout,
                               logger: logger)

        let job = try await poller.waitForCompletion(jobID: jobID) { job in
            // Prefer server-reported percentages; fall back to a time estimate.
            let reported = processingTaskNames.compactMap { job.task(named: $0)?.percent }
            let fraction: Double
            if !reported.isEmpty {
                fraction = reported.reduce(0, +) / Double(reported.count) / 100
            } else {
                let finished = processingTaskNames.filter { job.task(named: $0)?.status == .finished }.count
                let timeBased = ProcessingProgressEstimator.estimate(elapsed: Date().timeIntervalSince(processingStart), expectedDuration: expected)
                let share = processingTaskNames.isEmpty ? 0 : Double(finished) / Double(processingTaskNames.count)
                fraction = max(share, timeBased)
            }
            reporter.processing(fraction: fraction, jobID: jobID)
        }

        switch job.status {
        case .finished:
            guard let export = job.task(named: record.specification.exportTaskName),
                  let files = export.result?.files, !files.isEmpty else {
                throw CloudConvertError.exportMissing(jobID: jobID)
            }
            // Keep `finalURL` for files a previous launch already saved.
            let previous = record.exportedFiles
            record.exportedFiles = files.enumerated().map { index, file in
                var entry = ExportedFileRecord(file)
                if index < previous.count, previous[index].url == file.url {
                    entry.finalURL = previous[index].finalURL
                }
                return entry
            }
            await store.save(record)
            return job
        case .error:
            throw failure(for: job)
        case .waiting, .processing:
            throw CloudConvertError.jobTimedOut(jobID: jobID)
        }
    }

    private func downloadOutputs(_ record: inout ConversionRecord, reporter: ProgressReporter) async throws -> [ConvertedFile] {
        record.phase = .downloading
        await store.save(record)

        let expectedBytes = record.exportedFiles.compactMap(\.size).saturatingSum()
        try storage.ensureDiskSpace(forExpectedBytes: expectedBytes > 0 ? expectedBytes : record.totalInputBytes)

        for (index, file) in record.exportedFiles.enumerated() {
            reporter.registerDownload(index: index, totalBytes: file.size)
            if file.finalURL != nil { reporter.downloadFinished(index: index) }
        }
        reporter.stage(.downloading, jobID: record.jobID)

        let downloadDirectory = storage.downloadsDirectory.appendingPathComponent(record.id, isDirectory: true)
        try storage.ensureDirectory(downloadDirectory)

        var results: [ConvertedFile] = []
        for (index, exported) in record.exportedFiles.enumerated() {
            if let finalURL = exported.finalURL, FileManager.default.fileExists(atPath: finalURL.path) {
                results.append(ConvertedFile(url: finalURL, filename: finalURL.lastPathComponent,
                                             size: (try? storage.fileSize(at: finalURL)) ?? exported.size ?? 0))
                continue
            }

            let temporary = downloadDirectory.appendingPathComponent("\(index)-\(FileStorage.sanitizedFilename(exported.filename))")
            let downloaded = try await downloadOne(index: index, exported: exported, to: temporary, record: &record, reporter: reporter)

            let finalName = outputFilename(for: exported, index: index, record: record)
            let finalURL = try storage.finalize(downloadedFile: downloaded, preferredName: finalName, into: record.output.directory)
            record.exportedFiles[index].finalURL = finalURL
            record.downloadTransfers.removeValue(forKey: index)
            await store.save(record)
            reporter.downloadFinished(index: index)

            results.append(ConvertedFile(url: finalURL, filename: finalURL.lastPathComponent,
                                         size: (try? storage.fileSize(at: finalURL)) ?? exported.size ?? 0))
            logger.info("Conversion \(record.id): saved output \(index + 1) of \(record.exportedFiles.count)",
                        metadata: ["file": finalURL.lastPathComponent])
        }
        return results
    }

    private func downloadOne(index: Int,
                             exported: ExportedFileRecord,
                             to destination: URL,
                             record: inout ConversionRecord,
                             reporter: ProgressReporter) async throws -> URL {
        // Re-attach to the download a previous launch started; as for uploads,
        // anything but a lost transfer is the first attempt of the loop below.
        var reattachFailure: Error?
        if let existingID = record.downloadTransfers[index] {
            do {
                let outcome = try await transfers.awaitExistingTransfer(id: existingID) { [reporter] in
                    reporter.download(index: index, progress: $0)
                }
                // Failed without a response while the app was not running: download again.
                if outcome.status != nil, let url = try validateDownload(outcome, exported: exported) {
                    transfers.forget(id: existingID)
                    return url
                }
            } catch CloudConvertError.transferLost {
            } catch {
                reattachFailure = error
            }
            transfers.forget(id: existingID)
        }

        let request: URLRequest = {
            var request = URLRequest(url: exported.url)
            request.httpMethod = "GET"
            return request
        }()

        let conversionID = record.id
        let jobID = record.jobID
        let attemptBase = record.jobAttempt
        let downloadAttempt = Counter()
        let transfers = self.transfers
        let store = self.store
        let firstFailure = reattachFailure
        let recordBox = RecordBox(record)
        defer { record = recordBox.value }
        let waitForNetwork = makeNetworkWaiter(reporter: reporter, restoreTo: .downloading)

        return try await retrying(policy: configuration.downloadRetryPolicy, phase: .downloading, logger: logger,
                                  label: "download \(index)", waitForNetwork: waitForNetwork,
                                  onRetry: { attempt, delay, error in
            reporter.stage(.retrying(attempt: attempt, delay: delay, scope: .phase(.downloading), reason: error.analyticsCode), jobID: jobID)
        },
                                  operation: { () async throws -> URL in
            reporter.stage(.downloading, jobID: jobID)
            let attempt = downloadAttempt.increment()
            if attempt == 1, let firstFailure { throw firstFailure }
            let transferID = "\(conversionID)-dl-\(index)-a\(attemptBase)-\(attempt)"
            recordBox.update { $0.downloadTransfers[index] = transferID }
            await store.save(recordBox.value)

            let outcome = try await transfers.download(id: transferID, request: request, destination: destination) { [reporter] in
                reporter.download(index: index, progress: $0)
            }
            transfers.forget(id: transferID)
            guard let url = try self.validateDownload(outcome, exported: exported) else {
                throw CloudConvertError.downloadFailed(url: exported.url, status: outcome.status, description: "Downloaded file missing")
            }
            return url
        })
    }

    /// Returns the downloaded file URL for a good outcome, throws for a bad one.
    private func validateDownload(_ outcome: TransferOutcome, exported: ExportedFileRecord) throws -> URL? {
        guard let status = outcome.status else {
            throw CloudConvertError.network(code: .unknown, description: outcome.errorDescription ?? "No response from download")
        }
        guard (200...299).contains(status) else {
            // Export URLs expire with the job (24 h) and 403/404 mean it is gone.
            if status == 403 || status == 404 || status == 410 {
                throw CloudConvertError.jobLost(jobID: "export")
            }
            throw CloudConvertError.downloadFailed(url: exported.url, status: status, description: outcome.errorDescription)
        }
        guard let url = outcome.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        // An empty file is a failed download, unless the server said so too.
        let size = (try? storage.fileSize(at: url)) ?? 0
        guard size > 0 || exported.size == 0 else {
            throw CloudConvertError.downloadFailed(url: exported.url, status: status, description: "Empty file")
        }
        return url
    }

    private func outputFilename(for exported: ExportedFileRecord, index: Int, record: ConversionRecord) -> String {
        var serverName = FileStorage.sanitizedFilename(exported.filename)
        if (serverName as NSString).pathExtension.isEmpty, let hint = record.outputFormatHint {
            serverName = FileStorage.outputName(for: serverName, outputFormat: hint)
        }
        guard record.exportedFiles.count == 1 else { return serverName }

        if let base = record.output.preferredBaseName, !base.isEmpty {
            let ext = (serverName as NSString).pathExtension
            return FileStorage.sanitizedFilename(ext.isEmpty ? base : "\(base).\(ext)")
        }
        // Single input, single output: keep the user's file name with the new extension.
        if record.staged.count == 1, let staged = record.staged.values.first {
            let ext = (serverName as NSString).pathExtension
            return FileStorage.outputName(for: staged.filename, outputFormat: ext.isEmpty ? (record.outputFormatHint ?? "") : ext)
        }
        return serverName
    }

    // MARK: - Failure mapping

    private func failure(for job: CCJob) -> CloudConvertError {
        let task = job.failedTask
        let code = task.map(TaskFailureCode.init(task:)) ?? TaskFailureCode(rawCode: nil)
        // The server's message can quote the file: metadata, which the default logger keeps private.
        logger.error("Job \(job.id) failed: task=\(task?.name ?? "-") code=\(task?.code ?? "-")",
                     metadata: ["message": task?.message ?? "-"])
        return .jobFailed(jobID: job.id, taskName: task?.name, code: code, message: task?.message)
    }

    // MARK: - Network waiting

    private func makeNetworkWaiter(reporter: ProgressReporter, restoreTo stage: ConversionProgress.Stage) -> @Sendable () async throws -> Void {
        let connectivity = self.connectivity
        let timeout = configuration.offlineWaitTimeout
        return {
            reporter.stage(.waitingForNetwork)
            defer { reporter.stage(stage) }
            try await connectivity.waitUntilConnected(timeout: timeout)
        }
    }

    private func waitForNetworkIfNeeded(reporter: ProgressReporter, restoreTo stage: ConversionProgress.Stage) async throws {
        let connected = await connectivity.isConnected
        guard !connected else { return }
        try await makeNetworkWaiter(reporter: reporter, restoreTo: stage)()
    }

    // MARK: - Cleanup

    private func abortTransfers(_ record: ConversionRecord) {
        for id in record.uploadTransfers.values { transfers.cancel(id: id); transfers.forget(id: id) }
        for id in record.downloadTransfers.values { transfers.cancel(id: id); transfers.forget(id: id) }
    }

    /// Removes temp files and the persisted record. Safe to call from a
    /// cancelled task: `ConversionRecordStore.delete` never suspends on cancellation.
    private func finishLocally(_ record: ConversionRecord) async {
        storage.cleanup(conversionID: record.id)
        await store.delete(id: record.id)
    }

    /// Outputs already saved by a conversion that will not complete. Nobody
    /// was told about them, so they must not stay in the output directory.
    private func removeSavedOutputs(_ record: ConversionRecord) {
        for url in record.exportedFiles.compactMap(\.finalURL) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deleting the job removes the uploaded input and the output from
    /// CloudConvert storage immediately instead of after 24 h. Best effort,
    /// detached so it also runs when the current task is cancelled.
    private func deleteRemoteJobDetached(_ jobID: String) {
        let api = self.api
        let logger = self.logger
        Task.detached(priority: .utility) {
            do {
                try await api.deleteJob(id: jobID)
                logger.debug("Deleted remote job \(jobID)")
            } catch {
                logger.debug("Could not delete remote job \(jobID): \(CloudConvertError.wrap(error, phase: .finishing).analyticsCode)")
            }
        }
    }
}

// MARK: - Handle

/// A running conversion: observe `progress`, await `result`, or `cancel()`.
public final class ConversionHandle: @unchecked Sendable {
    public let id: String
    /// Coalesced progress (only the newest value is buffered). Finishes when
    /// the conversion reaches a terminal stage.
    public let progress: AsyncStream<ConversionProgress>
    private let task: Task<ConversionResult, Error>

    init(id: String = UUID().uuidString, progress: AsyncStream<ConversionProgress>, task: Task<ConversionResult, Error>) {
        self.id = id
        self.progress = progress
        self.task = task
    }

    public var result: ConversionResult {
        get async throws { try await task.value }
    }

    public var isCancelled: Bool { task.isCancelled }

    public func cancel() {
        task.cancel()
    }
}

// MARK: - Helpers

private final class ActiveConversions: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) {
        lock.lock(); ids.insert(id); lock.unlock()
    }

    /// Returns `false` if the id was already active.
    func insertIfAbsent(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.insert(id).inserted
    }

    func remove(_ id: String) {
        lock.lock(); ids.remove(id); lock.unlock()
    }

    var snapshot: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return ids
    }
}

/// The conversions `resumePendingConversions` started, by id, so more
/// handles can follow one. One that fails for good, or is cancelled, is
/// dropped: trying it again starts it over.
private final class ResumedConversions: @unchecked Sendable {
    private struct Entry {
        let token: UUID
        let task: Task<ConversionResult, Error>
        let progress: ProgressBroadcast
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Runs `body` as the conversion `id`, registered before it can end.
    func start(_ id: String,
               _ body: @escaping @Sendable (ProgressBroadcast) async throws -> ConversionResult) -> ConversionHandle {
        let token = UUID(), progress = ProgressBroadcast()
        lock.lock(); defer { lock.unlock() }
        let task = Task<ConversionResult, Error> {
            defer { progress.finish() }
            do {
                return try await body(progress)
            } catch {
                if !CloudConvertError.wrap(error, phase: .preparing).isResumable { remove(id, token: token) }
                throw error
            }
        }
        entries[id] = Entry(token: token, task: task, progress: progress)
        return ConversionHandle(id: id, progress: progress.makeStream(), task: task)
    }

    func handle(_ id: String) -> ConversionHandle? {
        lock.lock(); defer { lock.unlock() }
        return entries[id].map { ConversionHandle(id: id, progress: $0.progress.makeStream(), task: $0.task) }
    }

    func remove(_ id: String, token: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if token == nil || entries[id]?.token == token { entries[id] = nil }
    }
}

/// One conversion's progress for every handle on it. A stream made later
/// starts from the latest progress; all of them end with the conversion.
private final class ProgressBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<ConversionProgress>.Continuation] = []
    private var latest: ConversionProgress?
    private var finished = false

    func makeStream() -> AsyncStream<ConversionProgress> {
        let (stream, continuation) = ConversionEngine.makeProgressStream()
        lock.lock(); defer { lock.unlock() }
        if let latest { continuation.yield(latest) }
        if finished { continuation.finish() } else { continuations.append(continuation) }
        return stream
    }

    func yield(_ progress: ConversionProgress) {
        lock.lock(); defer { lock.unlock() }
        latest = progress
        continuations.forEach { $0.yield(progress) }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        continuations.forEach { $0.finish() }
        continuations = []
    }
}

/// Lets a `@Sendable` retry closure update a record that the caller owns
/// `inout`. The lock is belt-and-braces; the closure is never run concurrently.
private final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var record: ConversionRecord

    init(_ record: ConversionRecord) { self.record = record }

    var value: ConversionRecord {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    func update(_ body: (inout ConversionRecord) -> Void) {
        lock.lock(); body(&record); lock.unlock()
    }
}

/// Runs an operation that must not be abandoned half-way when the caller is
/// cancelled (`POST /jobs`: the server may create the job either way).
enum CancellationShield {

    /// Runs `operation` in its own task. If the caller is cancelled first, the
    /// caller gets `.cancelled` immediately; the operation keeps running and
    /// its value, if any, is handed to `onAbandoned` for cleanup.
    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T,
                                 onAbandoned: @escaping @Sendable (T) -> Void) async throws -> T {
        let state = State<T>(onAbandoned: onAbandoned)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard state.install(continuation) else { return }
                Task {
                    do {
                        state.complete(.success(try await operation()))
                    } catch {
                        state.complete(.failure(error))
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private final class State<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var cancelled = false
        private let onAbandoned: @Sendable (T) -> Void

        init(onAbandoned: @escaping @Sendable (T) -> Void) { self.onAbandoned = onAbandoned }

        /// Returns `false` (and fails the continuation) when already cancelled,
        /// in which case the operation must not be started at all.
        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                continuation.resume(throwing: CloudConvertError.cancelled)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(throwing: CloudConvertError.cancelled)
        }

        func complete(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            if let pending {
                pending.resume(with: result)
            } else if case .success(let value) = result {
                onAbandoned(value)
            }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
