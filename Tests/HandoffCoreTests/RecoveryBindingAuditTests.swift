import XCTest
import Foundation
@testable import HandoffCore

final class RecoveryBindingAuditTests: XCTestCase {
    func testRecoveryRechecksSourceAndDestinationBindingsAfterLock() throws {
        for field in ["sourcePath", "sourceIdentity", "destinationPath", "destinationIdentity"] {
            let f = try JobIntegrationTests.Fixture(clips: 1)
            defer { f.clean() }
            let token = CancellationToken()
            XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(count: 1), cancellation: token) { _ in token.cancel() })
            var changed = try JobEngine.loadState(destinationURL: f.destination)
            switch field {
            case "sourcePath": changed.preflight.configuration.sourcePath += "-different-originals"
            case "sourceIdentity": changed.preflight.sourceIdentity.inode += 1
            case "destinationPath": changed.preflight.destination.canonicalPath += "-different-delivery"
            default: changed.preflight.destination.identity.inode += 1
            }
            var injected = false
            XCTAssertThrowsError(try JobEngine().resume(destinationURL: f.destination) { progress in
                guard progress.operation == "Rechecking recovery state under destination lock" else { return }
                do {
                    try JobEngine.encoder().encode(changed).write(to: f.destination.appendingPathComponent(JobEngine.stateName))
                    injected = true
                } catch { XCTFail(error.localizedDescription) }
            }, "Recovery must reject the changed \(field) before publishing evidence for the wrong binding.")
            XCTAssertTrue(injected)
            XCTAssertFalse(try f.names().contains { $0.hasSuffix(".zip") })
        }
    }

    func testInvalidLockedRecordDoesNotRenamePendingArtifacts() throws {
        let f = try JobIntegrationTests.Fixture(clips: 1)
        defer { f.clean() }
        let token = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(count: 1), cancellation: token) { _ in token.cancel() })
        var changed = try JobEngine.loadState(destinationURL: f.destination)
        changed.schemaVersion = 999
        let pendingName = ".HANDOFF_LOG.txt.pending"
        let bytes = Data("preserve this interrupted artifact exactly".utf8)
        try bytes.write(to: f.destination.appendingPathComponent(pendingName))
        var injected = false
        XCTAssertThrowsError(try JobEngine().resume(destinationURL: f.destination) { progress in
            guard progress.operation == "Rechecking recovery state under destination lock" else { return }
            do {
                try JobEngine.encoder().encode(changed).write(to: f.destination.appendingPathComponent(JobEngine.stateName))
                injected = true
            } catch { XCTFail(error.localizedDescription) }
        })
        XCTAssertTrue(injected)
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent(pendingName)), bytes)
        XCTAssertFalse(try f.names().contains { $0.contains(".interrupted-") })
    }
}
