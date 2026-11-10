//  Files, the real job responses in Fixtures/, the test configuration, and
//  conversions a previous launch left behind.
//

import Foundation
import XCTest
@testable import CloudConvertKit

enum TestFiles {
    static func temporaryDirectory(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudConvertKitTests-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeFile(named name: String, bytes: Int = 1024, in directory: URL = temporaryDirectory()) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func job(_ name: String) throws -> CCJob {
        try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: data(name)).data
    }

    /// The `POST /jobs` response for a job shaped like the fixtures
    /// (`import` → `convert` → `export`), with a fresh upload form.
    static func createdJob(id: String) -> Data {
        let expires = Int(Date().timeIntervalSince1970) + 3600
        return Data("""
        {"data":{"id":"\(id)","tag":"example-app","status":"waiting","created_at":"2026-09-29T15:51:19+00:00",
          "tasks":[
            {"id":"t-export","name":"export","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"export/url","result":null,"credits":null},
            {"id":"t-convert","name":"convert","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"convert","engine":null,"result":null,"credits":null},
            {"id":"t-import","name":"import","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"import/upload","credits":null,
             "result":{"form":{"url":"https://upload.cloudconvert.com/x/","parameters":{"expires":\(expires),"max_file_count":1,"max_file_size":10000000000,"signature":"sig"}}}}]}}
        """.utf8)
    }
}

extension CloudConvertConfiguration {
    static func testing(workingDirectory: URL = TestFiles.temporaryDirectory("work"),
                        outputDirectory: URL = TestFiles.temporaryDirectory("out")) -> CloudConvertConfiguration {
        var configuration = CloudConvertConfiguration(environment: .sandbox,
                                                      authorizationProvider: NoAuthorization(),
                                                      backgroundSessionIdentifier: "tests.\(UUID().uuidString)",
                                                      workingDirectory: workingDirectory,
                                                      outputDirectory: outputDirectory,
                                                      logger: SilentCloudConvertLogger())
        configuration.jobRetryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.uploadRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.downloadRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.apiRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.polling = PollingPolicy(initialInterval: 0.01, maxInterval: 0.02, multiplier: 1.5, jobTimeout: 5, maxConsecutiveFailures: 3)
        configuration.diskSpaceSafetyMargin = 0
        return configuration
    }
}

/// A conversion a previous launch left behind: its input staged and its job
/// (`jobID`) created, saved where the engine finds pending records.
@discardableResult
func seedPreviousLaunch(id: String = "previous",
                        phase: ConversionPhase,
                        jobID: String = "job-9",
                        configuration: CloudConvertConfiguration,
                        api: FakeCloudConvertAPI,
                        change: (inout ConversionRecord) -> Void = { _ in }) async throws -> ConversionRecord {
    let url = try TestFiles.makeFile(named: "book.epub")
    let specification = try ConversionRequest.convert(url, to: "mobi").makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
    let storage = FileStorage(workingDirectory: configuration.workingDirectory, outputDirectory: configuration.outputDirectory,
                              diskSpaceSafetyMargin: 0)
    let staged = try storage.stage(InputFile(url: url), conversionID: id, limit: .max)
    var record = ConversionRecord(id: id,
                                  specification: specification,
                                  staged: ["import-1": staged],
                                  output: .default,
                                  userInfo: [:],
                                  createdAt: Date().addingTimeInterval(-60),
                                  updatedAt: Date(),
                                  phase: phase,
                                  jobAttempt: 1,
                                  jobID: jobID,
                                  uploadTransfers: [:],
                                  uploadedTaskNames: phase == .uploading ? [] : ["import-1"],
                                  downloadTransfers: [:],
                                  exportedFiles: [])
    change(&record)
    await ConversionRecordStore(directory: storage.recordsDirectory, logger: SilentCloudConvertLogger()).save(record)
    api.seededSpecification = specification
    return record
}
