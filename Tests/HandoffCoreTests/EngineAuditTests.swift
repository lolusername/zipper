import XCTest
import Foundation
@testable import HandoffCore

final class EngineAuditTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let configuration: JobConfiguration
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-engine-audit-\(UUID().uuidString)")
            source = root.appendingPathComponent("source")
            destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["A001", "A002"] {
                try Data(repeating: 0x23, count: 131_071).write(to: source.appendingPathComponent("\(name).mov"))
                try Data("<clip id=\"\(name)\"/>".utf8).write(to: source.appendingPathComponent("\(name).xml"))
            }
            configuration = JobConfiguration(sourcePath: source.path, destinationPath: destination.path, mode: .archiveCount(2))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        @discardableResult func create(progress: @escaping JobEngine.ProgressHandler = { _ in }) throws -> JobRecord {
            try JobEngine().create(preflight: Preflight.analyze(configuration), progress: progress)
        }
        func corrupt(_ name: String) throws {
            let path = destination.appendingPathComponent(name)
            var data = try Data(contentsOf: path)
            data[0] ^= 1
            try data.write(to: path)
        }
    }

    func testPreviouslyCheckedArchiveCannotChangeWhileLaterArchiveIsVerified() throws {
        for deep in [false, true] {
            let fixture = try Fixture()
            let job = try fixture.create()
            var changed = false
            let report = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: deep) { progress in
                if !changed && progress.currentArchive == job.archives[1].plan.name {
                    do { try fixture.corrupt(job.archives[0].plan.name); changed = true }
                    catch { XCTFail(error.localizedDescription) }
                }
            }
            XCTAssertTrue(changed)
            XCTAssertFalse(report.passed, "An earlier archive changed after its own verification completed.")
            XCTAssertEqual(report.checkedArchives, 1)
            XCTAssertTrue(report.issues.contains { $0.contains(job.archives[0].plan.name) })
        }
    }

    func testPreviouslyPromotedArchiveCannotChangeBeforeJobCompletion() throws {
        let fixture = try Fixture()
        var changed = false
        XCTAssertThrowsError(try fixture.create { progress in
            if !changed && progress.operation == "Final source stability check · SHA-256" {
                do { try fixture.corrupt("FOOTAGE_001.zip"); changed = true }
                catch { XCTFail(error.localizedDescription) }
            }
        })
        XCTAssertTrue(changed)
        let state = try JobEngine.loadState(destinationURL: fixture.destination)
        XCTAssertNotEqual(state.status, .completed)
        XCTAssertFalse(state.finalSourceVerified)
    }

    func testArchiveCannotChangeDuringPublishingStage() throws {
        let fixture = try Fixture()
        var changed = false
        XCTAssertThrowsError(try fixture.create { progress in
            if !changed && progress.operation == "Publishing verified delivery reports" {
                do { try fixture.corrupt("FOOTAGE_001.zip"); changed = true }
                catch { XCTFail(error.localizedDescription) }
            }
        })
        XCTAssertTrue(changed)
        XCTAssertNotEqual(try JobEngine.loadState(destinationURL: fixture.destination).status, .completed)
    }

    func testSourceModificationAtPublishingStageCannotLeavePassingManifest() throws {
        let fixture = try Fixture()
        var changed = false
        XCTAssertThrowsError(try fixture.create { progress in
            if !changed && progress.operation == "Publishing verified delivery reports" {
                do {
                    var bytes = try Data(contentsOf: fixture.source.appendingPathComponent("A001.mov"))
                    bytes[0] ^= 1
                    try bytes.write(to: fixture.source.appendingPathComponent("A001.mov"))
                    changed = true
                } catch { XCTFail(error.localizedDescription) }
            }
        })
        XCTAssertTrue(changed)
        do {
            let report = try HandoffVerifier.verify(destinationURL: fixture.destination)
            XCTAssertFalse(report.passed, "Failed final source stability cannot leave a passing delivery manifest.")
        } catch { /* A missing or explicitly incomplete final manifest is also a safe rejection. */ }
    }

    func testCancellationAtPublishingStageCannotBecomeSuccess() throws {
        let fixture = try Fixture()
        let token = CancellationToken()
        var cancelled = false
        XCTAssertThrowsError(try JobEngine().create(preflight: Preflight.analyze(fixture.configuration), cancellation: token) { progress in
            if progress.operation == "Publishing verified delivery reports" { token.cancel(); cancelled = true }
        }) { error in XCTAssertEqual(error as? HandoffError, .cancelled) }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try JobEngine.loadState(destinationURL: fixture.destination).status, .interrupted)
    }

    func testRequiredReportsMustAllExistAndBeReadable() throws {
        let fixture = try Fixture()
        try fixture.create()
        for name in ["HANDOFF_MANIFEST.txt", "SHA256SUMS.txt", "HANDOFF_LOG.txt"] {
            let path = fixture.destination.appendingPathComponent(name)
            let bytes = try Data(contentsOf: path)
            try FileManager.default.removeItem(at: path)
            let report = try HandoffVerifier.verify(destinationURL: fixture.destination)
            XCTAssertFalse(report.passed, "Required report \(name) is missing.")
            XCTAssertTrue(report.issues.contains { $0.contains(name) })
            try bytes.write(to: path)
        }
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: fixture.destination).passed)
    }

    func testChecksumsReportMustMatchJSONEvidence() throws {
        let fixture = try Fixture()
        try fixture.create()
        try Data("0000  FOOTAGE_001.zip\n".utf8).write(to: fixture.destination.appendingPathComponent("SHA256SUMS.txt"))
        let report = try HandoffVerifier.verify(destinationURL: fixture.destination)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.contains("SHA256SUMS.txt") })
    }

    func testReportsChangingDuringArchiveVerificationFail() throws {
        for name in ["HANDOFF_MANIFEST.json", "HANDOFF_MANIFEST.txt", "SHA256SUMS.txt", "HANDOFF_LOG.txt"] {
            let fixture = try Fixture()
            try fixture.create()
            var changed = false
            let report = try HandoffVerifier.verify(destinationURL: fixture.destination) { _ in
                if !changed {
                    do { try fixture.corrupt(name); changed = true }
                    catch { XCTFail(error.localizedDescription) }
                }
            }
            XCTAssertTrue(changed)
            XCTAssertFalse(report.passed)
            XCTAssertTrue(report.issues.contains { $0.contains(name) })
        }
    }

    func testInterruptedReportPublicationCannotPassDeliveryCheckAndCanResume() throws {
        let fixture = try Fixture()
        var injected = false
        XCTAssertThrowsError(try fixture.create { progress in
            if !injected && progress.operation == "Publishing verified delivery reports" {
                do {
                    try Data("interrupted write".utf8).write(to: fixture.destination.appendingPathComponent(".HANDOFF_MANIFEST.txt.pending"))
                    injected = true
                } catch { XCTFail(error.localizedDescription) }
            }
        })
        XCTAssertTrue(injected)
        let provisional = try JobEngine.readRecord(name: JobEngine.manifestName, destination: Destination(url: fixture.destination))
        XCTAssertNotEqual(provisional.status, .completed)
        XCTAssertFalse(provisional.finalSourceVerified)
        XCTAssertThrowsError(try HandoffVerifier.verify(destinationURL: fixture.destination))
        let resumed = try JobEngine().resume(destinationURL: fixture.destination)
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: fixture.destination).passed)
    }

    func testManifestCannotCarryConflictingPreflightPackages() throws {
        let fixture = try Fixture()
        var job = try fixture.create()
        job.preflight.packages[0].media.identity.size = UInt64.max
        XCTAssertThrowsError(try JobEngine.validateRecord(job, requireComplete: true))
    }

    func testManifestBatchCountMustAgreeWithActualPartition() throws {
        let fixture = try Fixture()
        var job = try fixture.create()
        job.preflight.configuration.mode = .archiveCount(3)
        XCTAssertThrowsError(try JobEngine.validateRecord(job, requireComplete: true))
    }

    func testManifestCannotBypassOversizedAcknowledgment() throws {
        let fixture = try Fixture()
        var job = try fixture.create()
        job.preflight.configuration.mode = .maximumBytes(1)
        job.preflight.configuration.acknowledgedOversized = false
        for index in job.archives.indices { job.archives[index].plan.oversized = true }
        job.preflight.archives = job.archives.map(\.plan)
        XCTAssertThrowsError(try JobEngine.validateRecord(job, requireComplete: true))
    }

    func testSymlinkRequiredReportIsRejected() throws {
        let fixture = try Fixture()
        try fixture.create()
        let report = fixture.destination.appendingPathComponent("HANDOFF_LOG.txt")
        try FileManager.default.moveItem(at: report, to: fixture.root.appendingPathComponent("outside-log.txt"))
        try FileManager.default.createSymbolicLink(at: report, withDestinationURL: fixture.root.appendingPathComponent("outside-log.txt"))
        XCTAssertFalse(try HandoffVerifier.verify(destinationURL: fixture.destination).passed)
    }
}
