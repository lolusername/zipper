import XCTest
import Foundation
import Darwin
@testable import HandoffCore

/// Concurrent fault injection is confined to disposable delivery fixtures.
final class PublicationConcurrencyAuditTests: XCTestCase {
    func testReportChangedBeforePublicCommitCannotReturnCompleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-publication-concurrency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let delivery = root.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        for index in 1...30 {
            let stem = String(format: "CLIP%03d", index)
            try Data(repeating: UInt8(index), count: 1_024).write(to: source.appendingPathComponent(stem + ".MOV"))
            try Data("<clip/>".utf8).write(to: source.appendingPathComponent(stem + ".XML"))
        }
        let plan = try Preflight.analyze(JobConfiguration(sourcePath: source.path, destinationPath: delivery.path, mode: .archiveCount(2)))
        let watcherDone = DispatchSemaphore(value: 0)
        let watcherStarted = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var injectedBeforeCommit = false
        var injectionError: Error?
        let reportURL = delivery.appendingPathComponent("HANDOFF_MANIFEST.txt")
        let publicURL = delivery.appendingPathComponent(JobEngine.manifestName)
        DispatchQueue.global().async {
            defer { watcherDone.signal() }
            watcherStarted.signal()
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: reportURL.path) {
                    do {
                        // The first JSON is explicitly provisional; assert this event occurs
                        // before publication commits a completed public record.
                        let publicRecord = try JobEngine.decoder().decode(JobRecord.self, from: Data(contentsOf: publicURL))
                        guard publicRecord.status != .completed else { return }
                        let handle = try FileHandle(forWritingTo: reportURL)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data("CONCURRENT REPORT CHANGE\n".utf8))
                        try handle.synchronize()
                        try handle.close()
                        let after = try JobEngine.decoder().decode(JobRecord.self, from: Data(contentsOf: publicURL))
                        resultLock.lock(); injectedBeforeCommit = after.status != .completed; resultLock.unlock()
                    } catch { resultLock.lock(); injectionError = error; resultLock.unlock() }
                    return
                }
                usleep(100)
            }
        }
        XCTAssertEqual(watcherStarted.wait(timeout: .now() + 5), .success)
        var completed: JobRecord?
        var creationError: Error?
        do { completed = try JobEngine().create(preflight: plan) }
        catch { creationError = error }
        XCTAssertEqual(watcherDone.wait(timeout: .now() + 20), .success)
        resultLock.lock(); let injected = injectedBeforeCommit; let faultError = injectionError; resultLock.unlock()
        XCTAssertNil(faultError)
        XCTAssertTrue(injected, "The fixture must inject the report change before completed JSON exists.")
        guard injected else { return }
        XCTAssertNotEqual(completed?.status, .completed,
                          "A required report changed during publication; creation must not return a completed handoff.")
        XCTAssertNotNil(creationError)
        let failed = try JobEngine.loadState(destinationURL: delivery)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertFalse(failed.finalSourceVerified)
        if let report = try? HandoffVerifier.verify(destinationURL: delivery) {
            XCTAssertFalse(report.passed)
            XCTAssertTrue(report.issues.contains { $0.contains("HANDOFF_MANIFEST.txt") })
        }
        let recovered = try JobEngine().resume(destinationURL: delivery)
        XCTAssertEqual(recovered.status, .completed)
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: delivery).passed)
    }
}
