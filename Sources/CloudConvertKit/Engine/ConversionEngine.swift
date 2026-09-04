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

    /// Records older than this are considered unrecoverable on resume; the
    /// server purges jobs after 24 h and upload forms expire long before.
    private let maxResumableAge: TimeInterval = 20 * 60 * 60

    /// - Parameters:
    ///   - api: Injected in tests. Defaults to `CloudConvertAPI` over URLSession.
    ///   - transfers: Injected in tests. Defaults to the `BackgroundTransferManager`
    ///     for `configuration.backgroundSessionIdentifier`, reusing an existing one
    ///     (a background session identifier must only ever be created once per process).
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
        self.transfers = transfers
            ?? BackgroundTransferManager.shared(for: configuration.backgroundSessionIdentifier)
            ?? BackgroundTransferManager(identifier: configuration.backgroundSessionIdentifier,
                                         registryDirectory: configuration.workingDirectory,
                                         usesBackgroundSession: configuration.usesBackgroundTransfers,
                                         allowsCellularAccess: configuration.allowsCellularTransfers,
                                         resourceTimeout: configuration.transferResourceTimeout,
                                         logger: configuration.logger)
        self.store = store ?? ConversionRecordStore(directory: storage.recordsDirectory, logger: configuration.logger)
        try? storage.prepareDirectories()
        storage.purgeStaleTemporaryFiles()
    }

    // MARK: - Public API: running conversions

    /// Runs a conversion to completion. Cancel by cancelling the calling task.
    /// `progress` is called on arbitrary threads.
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

    /// Conversions persisted by a previous launch that never completed.
    /// Conversions running in this process are excluded.
    public func pendingConversions() async -> [ConversionRecord] {
        let activeIDs = active.snapshot
        return await store.all().filter { !activeIDs.contains($0.id) }
    }

    /// Resumes every pending conversion. Call once at launch after the
    /// background session has been set up. Records that are too old, or whose
    /// staged inputs vanished, are cleaned up and reported as failures through
    /// the returned handles. Calling it twice never runs a record twice.
    public func resumePendingConversions() async -> [ConversionHandle] {
        let records = await pendingConversions()
        return records.compactMap { record in
            guard active.insertIfAbsent(record.id) else { return nil }
            let (stream, continuation) = ConversionEngine.makeProgressStream()
            let task = Task<ConversionResult, Error> { [self] in
                defer {
                    continuation.finish()
                    active.remove(record.id)
                }
                let reporter = ProgressReporter(conversionID: record.id, weights: configuration.progressWeights) { continuation.yield($0) }
                return try await resume(record, reporter: reporter)
            }
            return ConversionHandle(id: record.id, progress: stream, task: task)
        }
    }

    /// Forgets a pending conversion without running it: cancels its transfers,
    /// deletes the server job and removes local files and the record.
    public func discardPendingConversion(id: String) async {
        if let record = await store.load(id: id) {
            abortTransfers(record)
            if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }
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
                try storage.stage(input, conversionID: conversionID, limit: limit)
            }
        }
        let inputBytes = staged.values.reduce(Int64(0)) { $0 + $1.size }
        try storage.ensureDiskSpace(forExpectedBytes: output.expectedOutputBytes ?? inputBytes * 2)

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
    /// stage and cleans up local files, the record, transfers and the server job.
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

                if ccError.isCancellation {
                    await abandon(record, reporter: reporter, stage: .cancelled)
                    throw ccError
                }

                let attempt = record.jobAttempt
                guard shouldRebuildJob(after: ccError), configuration.jobRetryPolicy.shouldRetry(afterAttempt: attempt) else {
                    await abandon(record, reporter: reporter, stage: .failed)
                    throw ccError
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
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    // Cancelled while waiting to rebuild: clean up like any other cancellation.
                    await abandon(record, reporter: reporter, stage: .cancelled)
                    throw CloudConvertError.cancelled
                }
            }
        }
    }

    /// Whether a failed attempt is worth a brand-new job. Errors that
    /// invalidated this job (expired form, purged job, lost transfer) always
    /// are. Connectivity failures are not: the phase already waited
    /// `offlineWaitTimeout` for the network, so a rebuild would just wait again.
    private func shouldRebuildJob(after error: CloudConvertError) -> Bool {
        if error.requiresNewJob { return true }
        if error.isConnectivityRelated { return false }
        return error.isRetryable
    }

    private func abandon(_ record: ConversionRecord, reporter: ProgressReporter, stage: ConversionProgress.Stage) async {
        reporter.stage(stage, jobID: record.jobID)
        abortTransfers(record)
        if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }
        await finishLocally(record)
    }

    // MARK: - One job attempt

    private func runJob(_ record: inout ConversionRecord, reporter: ProgressReporter, startedAt: Date) async throws -> ConversionResult {
        var finishedJob: CCJob?

        // Resuming a conversion that already reached the download phase needs
        // no server round trip: the export URLs are in the record.
        let resumingDownload = record.phase == .downloading && !record.exportedFiles.isEmpty && record.jobID != nil
        if !resumingDownload {
            let job = try await ensureJob(&record, reporter: reporter)
            try await uploadInputs(&record, job: job, reporter: reporter)
            finishedJob = try await waitForJob(&record, reporter: reporter)
        }

        let files = try await downloadOutputs(&record, reporter: reporter)

        record.phase = .finishing
        reporter.stage(.finishing, jobID: record.jobID)
        if let jobID = record.jobID { deleteRemoteJobDetached(jobID) }

        let creditTasks = finishedJob?.tasks.filter { $0.credits != nil } ?? []
        return ConversionResult(conversionID: record.id,
                                jobID: record.jobID ?? finishedJob?.id ?? "",
                                files: files,
                                credits: creditTasks.isEmpty ? nil : creditTasks.compactMap(\.credits).reduce(0, +),
                                duration: Date().timeIntervalSince(startedAt),
                                userInfo: record.userInfo)
    }

    private func ensureJob(_ record: inout ConversionRecord, reporter: ProgressReporter) async throws -> CCJob {
        record.phase = .creatingJob
        reporter.stage(.creatingJob, jobAttempt: record.jobAttempt)

        if let jobID = record.jobID {
            // Resuming: fetch the job to recover upload forms / status.
            do {
                let job = try await api.getJob(id: jobID)
                if job.status == .error { throw failure(for: job) }
                return job
            } catch CloudConvertError.notFound {
                throw CloudConvertError.jobLost(jobID: jobID)
            }
        }

        try await waitForNetworkIfNeeded(reporter: reporter, restoreTo: .creatingJob)
        let job = try await api.createJob(record.specification)

        // Every upload task must have come back with a form, otherwise the
        // response is unusable and we must not proceed.
        for taskName in record.specification.uploadTaskNames {
            guard job.task(named: taskName)?.result?.form != nil else {
                logger.error("Job \(job.id): upload task \(taskName) has no form in the create response")
                throw CloudConvertError.uploadFormInvalid
            }
        }

        record.jobID = job.id
        await store.save(record)
        reporter.stage(.creatingJob, jobID: job.id)
        logger.info("Conversion \(record.id): created job \(job.id)")
        return job
    }

    private func uploadInputs(_ record: inout ConversionRecord, job: CCJob, reporter: ProgressReporter) async throws {
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
            if let serverTask = job.task(named: taskName), serverTask.status == .finished {
                if let existingID = record.uploadTransfers[taskName] { transfers.forget(id: existingID) }
                markUploaded(taskName, record: &record, reporter: reporter)
                await store.save(record)
                continue
            }

            // Resume case 2: re-attach to an upload that was still running.
            if let existingID = record.uploadTransfers[taskName] {
                do {
                    let outcome = try await transfers.awaitExistingTransfer(id: existingID) { [reporter] in
                        reporter.upload(taskName: taskName, progress: $0)
                    }
                    try validateUpload(outcome)
                    transfers.forget(id: existingID)
                    markUploaded(taskName, record: &record, reporter: reporter)
                    await store.save(record)
                    continue
                } catch CloudConvertError.transferLost {
                    logger.notice("Conversion \(record.id): upload \(taskName) was lost; restarting it")
                    transfers.forget(id: existingID)
                }
            }

            // Fresh upload: the form must exist, be unexpired and accept the size.
            guard let form = job.task(named: taskName)?.result?.form else {
                throw CloudConvertError.uploadFormInvalid
            }
            if form.isExpired {
                throw CloudConvertError.uploadFormExpired
            }
            if let limit = form.maxFileSize, staged.size > limit {
                throw CloudConvertError.fileTooLarge(staged.original.url, size: staged.size, limit: limit)
            }

            try await uploadOne(taskName: taskName, staged: staged, form: form, record: &record, reporter: reporter)
            markUploaded(taskName, record: &record, reporter: reporter)
            await store.save(record)
        }
    }

    private func uploadOne(taskName: String,
                           staged: StagedInput,
                           form: CCUploadForm,
                           record: inout ConversionRecord,
                           reporter: ProgressReporter) async throws {
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

        // Each HTTP attempt gets its own transfer id; the record always points
        // at the most recent one so a relaunch can re-attach to it.
        let recordBox = RecordBox(record)
        let store = self.store
        defer { record = recordBox.value }
        try await retrying(policy: configuration.uploadRetryPolicy, phase: .uploading, logger: logger,
                           label: "upload \(taskName)", waitForNetwork: waitForNetwork,
                           onRetry: { attempt, delay, error in
            reporter.stage(.retrying(attempt: attempt, delay: delay, scope: .phase(.uploading), reason: error.analyticsCode), jobID: jobID)
        },
                           operation: { () async throws -> Void in
            reporter.stage(.uploading, jobID: jobID)
            let attempt = uploadAttempt.increment()
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

    private func validateUpload(_ outcome: TransferOutcome) throws {
        guard let status = outcome.status else {
            throw CloudConvertError.network(code: .unknown, description: outcome.errorDescription ?? "No response from upload endpoint")
        }
        guard (200...299).contains(status) else {
            let snippet = outcome.responseBody.flatMap { String(data: $0.prefix(512), encoding: .utf8) }
            logger.error("Upload rejected with \(status): \(snippet ?? "<no body>")")
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
        let deadline = Date().addingTimeInterval(configuration.polling.jobTimeout)

        let job = try await poller.waitForCompletion(jobID: jobID, deadline: deadline) { job in
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

        let expectedBytes = record.exportedFiles.compactMap(\.size).reduce(0, +)
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
            logger.info("Conversion \(record.id): saved \(finalURL.lastPathComponent)")
        }
        return results
    }

    private func downloadOne(index: Int,
                             exported: ExportedFileRecord,
                             to destination: URL,
                             record: inout ConversionRecord,
                             reporter: ProgressReporter) async throws -> URL {
        // Re-attach to a download started before a relaunch.
        if let existingID = record.downloadTransfers[index] {
            do {
                let outcome = try await transfers.awaitExistingTransfer(id: existingID) { [reporter] in
                    reporter.download(index: index, progress: $0)
                }
                transfers.forget(id: existingID)
                if let url = try validateDownload(outcome, source: exported.url) { return url }
            } catch CloudConvertError.transferLost {
                transfers.forget(id: existingID)
            }
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
            let transferID = "\(conversionID)-dl-\(index)-a\(attemptBase)-\(attempt)"
            recordBox.update { $0.downloadTransfers[index] = transferID }
            await store.save(recordBox.value)

            let outcome = try await transfers.download(id: transferID, request: request, destination: destination) { [reporter] in
                reporter.download(index: index, progress: $0)
            }
            transfers.forget(id: transferID)
            guard let url = try self.validateDownload(outcome, source: exported.url) else {
                throw CloudConvertError.downloadFailed(url: exported.url, status: outcome.status, description: "Downloaded file missing")
            }
            return url
        })
    }

    /// Returns the downloaded file URL for a good outcome, throws for a bad one.
    private func validateDownload(_ outcome: TransferOutcome, source: URL) throws -> URL? {
        guard let status = outcome.status else {
            throw CloudConvertError.network(code: .unknown, description: outcome.errorDescription ?? "No response from download")
        }
        guard (200...299).contains(status) else {
            // Export URLs expire with the job (24 h) and 403/404 mean it is gone.
            if status == 403 || status == 404 || status == 410 {
                throw CloudConvertError.jobLost(jobID: "export")
            }
            throw CloudConvertError.downloadFailed(url: source, status: status, description: outcome.errorDescription)
        }
        guard let url = outcome.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let size = (try? storage.fileSize(at: url)) ?? 0
        guard size > 0 else {
            throw CloudConvertError.downloadFailed(url: source, status: status, description: "Empty file")
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
        let code = TaskFailureCode(rawCode: task?.code)
        logger.error("Job \(job.id) failed: task=\(task?.name ?? "-") code=\(task?.code ?? "-") message=\(task?.message ?? "-")")
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
                logger.debug("Could not delete remote job \(jobID): \(error)")
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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
