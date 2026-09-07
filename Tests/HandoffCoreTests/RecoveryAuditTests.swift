import XCTest
import Foundation
import CryptoKit
@testable import HandoffCore

/// Fault injection is confined to disposable directories; no production footage is opened.
final class RecoveryAuditTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-recovery-audit-\(UUID().uuidString)")
        var source: URL { root.appendingPathComponent("source") }
        var destination: URL { root.appendingPathComponent("destination") }
        init() throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for n in 115...117 {
                let base = "DISCLOSURE_DAY0\(n)"
                try Data(repeating: UInt8(n), count: 8_192 + n).write(to: source.appendingPathComponent(base + ".MXF"))
                try Data("<metadata id=\"\(base)\"/>".utf8).write(to: source.appendingPathComponent(base + "M01.XML"))
                try Data("binary sidecar \(base)".utf8).write(to: source.appendingPathComponent(base + "R01.BIM"))
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func plan() throws -> PreflightReport {
            try Preflight.analyze(JobConfiguration(sourcePath: source.path, destinationPath: destination.path, mode: .archiveCount(2)))
        }
        func injectPending(_ name: String) throws {
            try Data("interrupted durable write".utf8).write(to: destination.appendingPathComponent(".\(name).pending"))
        }
        func sourceHashes() throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: source.path).map { name in
                let hash = SHA256.hash(data: try Data(contentsOf: source.appendingPathComponent(name)))
                return (name, hash.map { String(format: "%02x", $0) }.joined())
            })
        }
    }

    func testLateReportFailureNeverLeavesAnUnqualifiedPassingHumanReport() throws {
        let f = try Fixture()
        let before = try f.sourceHashes()
        var injected = false
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan()) { progress in
            if progress.operation == "Publishing verified delivery reports", !injected {
                do { try f.injectPending("HANDOFF_LOG.txt"); injected = true }
                catch { XCTFail(error.localizedDescription) }
            }
        })
        XCTAssertTrue(injected)
        XCTAssertEqual(try JobEngine.loadState(destinationURL: f.destination).status, .failed)
        XCTAssertThrowsError(try HandoffVerifier.verify(destinationURL: f.destination))
        let humanURL = f.destination.appendingPathComponent("HANDOFF_MANIFEST.txt")
        if FileManager.default.fileExists(atPath: humanURL.path) {
            let human = try String(contentsOf: humanURL, encoding: .utf8)
            XCTAssertFalse(human.contains("Verification: PASS"),
                           "A failed publication must not leave a human report claiming overall handoff PASS while its JSON commit is incomplete.")
        }
        XCTAssertEqual(try f.sourceHashes(), before)
        XCTAssertEqual(try JobEngine().resume(destinationURL: f.destination).status, .completed)
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination).passed)
    }

    func testFinalStateWriteFailureCannotContradictCommittedDeliveryOutcome() throws {
        let f = try Fixture()
        let before = try f.sourceHashes()
        var injected = false
        var returned: JobRecord?
        var thrown: Error?
        do {
            returned = try JobEngine().create(preflight: f.plan()) { progress in
                if progress.operation == "Publishing verified delivery reports", !injected {
                    do { try f.injectPending(JobEngine.stateName); injected = true }
                    catch { XCTFail(error.localizedDescription) }
                }
            }
        } catch { thrown = error }
        XCTAssertTrue(injected)
        let delivery = try? HandoffVerifier.verify(destinationURL: f.destination)
        if thrown != nil {
            XCTAssertNotEqual(delivery?.passed, true,
                              "The engine threw failure, but its completed public manifest independently passes. Final-state persistence must honor one commit outcome.")
        } else {
            XCTAssertEqual(returned?.status, .completed)
            XCTAssertEqual(delivery?.passed, true)
        }
        XCTAssertEqual(try f.sourceHashes(), before)
        // The injected interrupted state file is retained and a retry recovers the result.
        XCTAssertEqual(try JobEngine().resume(destinationURL: f.destination).status, .completed)
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination).passed)
    }

    func testVerifiedPartialWithSavedEvidenceIsRecheckedAndPromotedOnResume() throws {
        let f = try Fixture()
        let token = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(), cancellation: token) { progress in
            if progress.verifiedArchives == 1 { token.cancel() }
        })
        let interrupted = try JobEngine.loadState(destinationURL: f.destination)
        let archive = try XCTUnwrap(interrupted.archives.first)
        let archiveURL = f.destination.appendingPathComponent(archive.plan.name)
        let before = try Data(contentsOf: archiveURL)
        let partialURL = f.destination.appendingPathComponent(".\(archive.plan.name).partial")
        // Recreate the durable crash boundary after evidence save but before rename.
        try FileManager.default.moveItem(at: archiveURL, to: partialURL)
        let resumed = try JobEngine().resume(destinationURL: f.destination)
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertTrue(resumed.events.contains { $0.message.contains("after rehashing and verifying the complete partial") })
        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination).passed)
    }

    func testCorruptVerifiedPartialIsPreservedAndCannotBeSilentlyRebuilt() throws {
        let f = try Fixture()
        let token = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(), cancellation: token) { progress in
            if progress.verifiedArchives == 1 { token.cancel() }
        })
        let interrupted = try JobEngine.loadState(destinationURL: f.destination)
        let archive = try XCTUnwrap(interrupted.archives.first)
        let archiveURL = f.destination.appendingPathComponent(archive.plan.name)
        let partialURL = f.destination.appendingPathComponent(".\(archive.plan.name).partial")
        try FileManager.default.moveItem(at: archiveURL, to: partialURL)
        var bytes = try Data(contentsOf: partialURL)
        bytes[80] ^= 1
        try bytes.write(to: partialURL)
        XCTAssertThrowsError(try JobEngine().resume(destinationURL: f.destination))
        XCTAssertEqual(try Data(contentsOf: partialURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent(JobEngine.manifestName).path))
        XCTAssertEqual(try JobEngine.loadState(destinationURL: f.destination).status, .failed)
    }

    func testRepeatedCancellationDuringResumeNeverPublishesSuccessOrChangesOriginals() throws {
        let f = try Fixture()
        let before = try f.sourceHashes()
        let initial = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(), cancellation: initial) { progress in
            if progress.verifiedArchives == 1 { initial.cancel() }
        })
        let kept = try Data(contentsOf: f.destination.appendingPathComponent("FOOTAGE_001.zip"))
        for operation in ["Hashing source", "Rechecking verified archive", "Publishing verified delivery reports"] {
            let token = CancellationToken()
            var boundaryReached = false
            XCTAssertThrowsError(try JobEngine().resume(destinationURL: f.destination, cancellation: token) { progress in
                if progress.operation == operation { boundaryReached = true; token.cancel() }
            }) { error in XCTAssertEqual(error as? HandoffError, .cancelled) }
            XCTAssertTrue(boundaryReached, operation)
            XCTAssertEqual(try JobEngine.loadState(destinationURL: f.destination).status, .interrupted)
            XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("FOOTAGE_001.zip")), kept)
            XCTAssertEqual(try f.sourceHashes(), before)
            XCTAssertThrowsError(try HandoffVerifier.verify(destinationURL: f.destination))
        }
        XCTAssertEqual(try JobEngine().resume(destinationURL: f.destination).status, .completed)
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination).passed)
    }

    func testInterruptedPublicationHasNoCompletionDateAndResumeRecordsCurrentCompletion() throws {
        let f = try Fixture()
        let token = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(), cancellation: token) { progress in
            if progress.operation == "Publishing verified delivery reports" { token.cancel() }
        })
        var interrupted = try JobEngine.loadState(destinationURL: f.destination)
        XCTAssertNil(interrupted.completedAt, "An interrupted report publication has not completed the handoff.")
        // Old releases saved an attempted completion date before final publication.
        interrupted.completedAt = Date(timeIntervalSince1970: 1_000)
        try JobEngine.encoder().encode(interrupted).write(to: f.destination.appendingPathComponent(JobEngine.stateName))
        let started = Date()
        let resumed = try JobEngine().resume(destinationURL: f.destination)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(resumed.completedAt), started,
                                    "Resume must not reuse the failed attempt's completion date.")
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination).passed)
    }
}
