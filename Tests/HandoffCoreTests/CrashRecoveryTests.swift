import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

final class CrashRecoveryTests: XCTestCase {
    private static let workerPhase = "ZIPPER_CRASH_TEST_PHASE"
    private static let workerRoot = "ZIPPER_CRASH_TEST_ROOT"

    /// Runs only in an explicitly selected child xctest process. _exit bypasses every
    /// Swift defer/catch and simulates abrupt process loss while kernel locks are held.
    func testCrashWorker() throws {
        guard let phase = ProcessInfo.processInfo.environment[Self.workerPhase],
              let path = ProcessInfo.processInfo.environment[Self.workerRoot] else { return }
        let root = URL(fileURLWithPath: path)
        let configuration = JobConfiguration(sourcePath: root.appendingPathComponent("source").path,
                                             destinationPath: root.appendingPathComponent("destination").path,
                                             mode: .archiveCount(2))
        let plan = try Preflight.analyze(configuration)
        _ = try JobEngine().create(preflight: plan) { progress in
            let boundary: Bool
            switch phase {
            case "archive-promoted": boundary = progress.verifiedArchives == 1
            case "member-verification": boundary = progress.operation.contains("Verifying archived members")
            case "report-publication": boundary = progress.operation == "Publishing verified delivery reports"
            default: boundary = false
            }
            if boundary { Darwin._exit(86) }
        }
        XCTFail("The child never reached its requested crash boundary: \(phase)")
        Darwin._exit(87)
    }

    func testAbruptProcessExitRecoversAtThreeDurableBoundaries() throws {
        for phase in ["archive-promoted", "member-verification", "report-publication"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-process-crash-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for index in 1...3 {
                let basename = String(format: "A001C%03d", index)
                try Data(repeating: UInt8(index), count: 131_071 + index).write(to: source.appendingPathComponent("\(basename).mov"))
                try Data("<clip id=\"\(basename)\"/>".utf8).write(to: source.appendingPathComponent("\(basename).xml"))
            }
            let before = try sourceSnapshot(source)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["-XCTest", "HandoffCoreTests.CrashRecoveryTests/testCrashWorker", Bundle(for: CrashRecoveryTests.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment[Self.workerPhase] = phase
            environment[Self.workerRoot] = root.path
            child.environment = environment
            let output = Pipe(); child.standardOutput = output; child.standardError = output
            try child.run()
            let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .exit, phase)
            XCTAssertEqual(child.terminationStatus, 86, "\(phase): \(log)")
            guard child.terminationStatus == 86 else { continue }
            let interrupted = try JobEngine.loadState(destinationURL: destination)
            XCTAssertNotEqual(interrupted.status, .completed, phase)
            do {
                let premature = try HandoffVerifier.verify(destinationURL: destination, deep: true)
                XCTAssertFalse(premature.passed, "A crashed, unfinished handoff must never pass delivery verification.")
            } catch { /* Missing/provisional manifests correctly reject unfinished delivery. */ }
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            XCTAssertTrue(names.contains(JobEngine.stateName), phase)
            XCTAssertTrue(names.contains(JobEngine.lockName), "The crashed process must leave its lock file; the OS releases its flock.")
            if phase == "member-verification" {
                XCTAssertTrue(names.contains(".FOOTAGE_001.zip.partial"))
                XCTAssertFalse(names.contains("FOOTAGE_001.zip"))
            } else { XCTAssertTrue(names.contains("FOOTAGE_001.zip")) }
            XCTAssertEqual(try sourceSnapshot(source), before, "Crash must not change source at \(phase)")
            let preserved = names.contains("FOOTAGE_001.zip") ? try Data(contentsOf: destination.appendingPathComponent("FOOTAGE_001.zip")) : nil
            let resumed = try JobEngine().resume(destinationURL: destination)
            XCTAssertEqual(resumed.status, .completed, phase)
            XCTAssertTrue(resumed.finalSourceVerified, phase)
            XCTAssertTrue(try HandoffVerifier.verify(destinationURL: destination, deep: true).passed, phase)
            XCTAssertEqual(try sourceSnapshot(source), before, "Resume must not change source at \(phase)")
            if let preserved { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("FOOTAGE_001.zip")), preserved) }
        }
    }

    private struct Snapshot: Equatable {
        var name: String
        var size: Int
        var sha256: String
    }
    private func sourceSnapshot(_ root: URL) throws -> [Snapshot] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        return try paths.map { path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            return Snapshot(name: path, size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }
}

final class LargeScalePreflightTests: XCTestCase {
    /// Logical sparse fixtures exercise 200 GB and 1 TB planning without writing or
    /// hashing those media payloads. Full-transfer throughput/durability is not claimed.
    func testSparseTwoHundredGBAndOneTBPlansStayBoundedAndNeverWriteDestination() throws {
        for clips in [200, 1_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-sparse-plan-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for index in 0..<clips {
                let basename = String(format: "A%06d", index)
                let fd = Darwin.open(sourceURL.appendingPathComponent("\(basename).mov").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw HandoffError.io("Cannot create sparse preflight fixture.") }
                guard ftruncate(fd, 1_000_000_000) == 0 else { Darwin.close(fd); throw HandoffError.io("Cannot size sparse preflight fixture.") }
                Darwin.close(fd)
                try Data("<clip id=\"\(basename)\"/>".utf8).write(to: sourceURL.appendingPathComponent("\(basename).xml"))
            }
            let source = try ReadOnlySource(url: sourceURL)
            let before = try source.scan()
            let allocatedBefore = try allocatedBytes(sourceURL)
            XCTAssertLessThan(allocatedBefore, 16 * 1_024 * 1_024, "The fixture must remain sparse.")
            var beforeUsage = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &beforeUsage), 0)
            let ceiling: UInt64 = 25_000_000_000
            let configuration = JobConfiguration(sourcePath: sourceURL.path, destinationPath: destination.path, mode: .maximumBytes(ceiling))
            let report = try Preflight.analyze(configuration)
            var afterUsage = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &afterUsage), 0)
            XCTAssertLessThan(afterUsage.ru_maxrss - beforeUsage.ru_maxrss, 256 * 1_024 * 1_024,
                              "Metadata-only planning should not allocate media-sized buffers.")
            XCTAssertEqual(report.packages.count, clips)
            XCTAssertEqual(report.files.count, clips * 2)
            XCTAssertGreaterThanOrEqual(report.totalBytes, UInt64(clips) * 1_000_000_000)
            XCTAssertEqual(report.archives.count, (clips + 23) / 24, "ZIP overhead prevents 25 complete 1 GB media packages fitting in 25 GB.")
            XCTAssertTrue(report.archives.allSatisfy { !$0.oversized && $0.predictedBytes <= ceiling })
            XCTAssertTrue(report.archives.allSatisfy { $0.predictedBytes == ZIPArchive.predictedSize(files: $0.files) })
            XCTAssertEqual(report.archives.flatMap(\.files).count, clips * 2)
            XCTAssertEqual(Set(report.archives.flatMap(\.files).map(\.relativePath)), Set(before.map(\.relativePath)))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
            XCTAssertEqual(try source.scan(), before)
            XCTAssertEqual(try allocatedBytes(sourceURL), allocatedBefore)
            // The real destination may have less than 1 TB available. Capacity failure is
            // correct and does not invalidate the exact partition generated by preflight.
            XCTAssertTrue(report.issues.allSatisfy { $0.hasPrefix("Insufficient destination capacity:") }, report.issues.joined(separator: "\n"))
        }
    }

    private func allocatedBytes(_ root: URL) throws -> UInt64 {
        try FileManager.default.contentsOfDirectory(atPath: root.path).reduce(0) { total, name in
            var metadata = stat()
            guard lstat(root.appendingPathComponent(name).path, &metadata) == 0 else { throw HandoffError.io("Cannot inspect sparse fixture allocation.") }
            return total + UInt64(metadata.st_blocks) * 512
        }
    }
}
