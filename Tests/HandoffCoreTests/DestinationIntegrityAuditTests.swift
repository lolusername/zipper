import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

/// Opt-in integrity attacks against newly manufactured disk images only.
final class DestinationIntegrityAuditTests: XCTestCase {
    func testHFSDestinationRequiresReadOnlyMountForIntegrityVerification() throws {
        try auditMountSafety(filesystem: "HFS+")
    }

    func testExFATDestinationRequiresReadOnlyMountForIntegrityVerification() throws {
        try auditMountSafety(filesystem: "ExFAT")
    }

    func testFAT32DestinationRequiresReadOnlyMountForIntegrityVerification() throws {
        try auditMountSafety(filesystem: "MS-DOS FAT32")
    }

    private func auditMountSafety(filesystem: String) throws {
        guard ProcessInfo.processInfo.environment["ZIPPER_RUN_DESTINATION_SAFETY_VOLUME_TESTS"] == "1" else {
            throw XCTSkip("Opt-in destination integrity test; uses only a disposable 128 MiB disk image.")
        }
        let fixture = try JobIntegrationTests.Fixture(clips: 2)
        var mayRemoveFixture = true
        defer { if mayRemoveFixture { fixture.clean() } }
        let job = try JobEngine().create(preflight: fixture.plan(count: 2))
        let mount = fixture.root.appendingPathComponent("destination-image")
        let image = fixture.root.appendingPathComponent("destination.dmg")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let created = try hdiutil(["create", "-size", "128m", "-fs", filesystem, "-volname", "ZIPPERDEST", "-type", "UDIF", "-layout", "NONE", image.path])
        guard created.0 == 0 else { throw HandoffError.io("Cannot create disposable destination: \(created.1)") }
        let attached = try hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        guard attached.0 == 0 else { throw HandoffError.io("Cannot attach disposable destination: \(attached.1)") }
        var isMounted = true
        defer {
            if isMounted {
                do {
                    var detached = try hdiutil(["detach", mount.path])
                    if detached.0 != 0 { detached = try hdiutil(["detach", "-force", mount.path]) }
                    if detached.0 != 0 { mayRemoveFixture = false }
                    XCTAssertEqual(detached.0, 0, "Disposable fixture retained at \(fixture.root.path): \(detached.1)")
                } catch {
                    mayRemoveFixture = false
                    XCTFail("Cannot detach disposable destination image; retained \(fixture.root.path): \(error)")
                }
            }
        }
        let delivery = mount.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: false)
        // Copy only the already-verified report/archive bytes. POSIX fixture writes avoid
        // Foundation provenance xattrs manufacturing AppleDouble members on exFAT.
        for name in JobEngine.reportNames + job.archives.map({ $0.plan.name }) {
            let bytes = try Data(contentsOf: fixture.destination.appendingPathComponent(name))
            let fd = Darwin.open(delivery.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw HandoffError.io("Cannot create disposable delivery member.") }
            do {
                try writeAll(bytes, descriptor: fd)
                guard fsync(fd) == 0 else { throw HandoffError.io("Cannot flush disposable delivery member.") }
                Darwin.close(fd)
            } catch { Darwin.close(fd); throw error }
            _ = removexattr(delivery.appendingPathComponent(name).path, "com.apple.provenance", 0)
        }
        // Remove OS-created provenance sidecars only from this manufactured test delivery.
        let directory = Darwin.open(delivery.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw HandoffError.io("Cannot inspect disposable fixture metadata.") }
        for name in try directoryNames(directory) where name.hasPrefix("._") {
            guard unlinkat(directory, name, 0) == 0 else { Darwin.close(directory); throw HandoffError.io("Cannot remove disposable fixture metadata.") }
        }
        Darwin.close(directory)
        let firstName = job.archives[0].plan.name
        // The original HFS+ regression rewrote byte 0 of an earlier checked ZIP,
        // restored mtime, and obtained PASS with unchanged coarse FileIdentity.
        // Reject that mutable volume before any public integrity-read path starts.
        for deep in [false, true] {
            XCTAssertThrowsError(try HandoffVerifier.verify(destinationURL: delivery, deep: deep))
        }
        do {
            let destination = try Destination(url: delivery)
            XCTAssertThrowsError(try ZIPArchive.hash(name: firstName, destination: destination, cancellation: CancellationToken()) { _ in })
            XCTAssertThrowsError(try ZIPArchive.verify(name: firstName, files: job.archives[0].plan.files,
                                                       destination: destination, cancellation: CancellationToken()) { _, _ in })
        }
        let detached = try hdiutil(["detach", mount.path])
        guard detached.0 == 0 else { throw HandoffError.io("Cannot detach disposable writable image: \(detached.1)") }
        isMounted = false
        let readOnly = try hdiutil(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        guard readOnly.0 == 0 else { throw HandoffError.io("Cannot attach disposable read-only destination: \(readOnly.1)") }
        isMounted = true
        for deep in [false, true] {
            let report = try HandoffVerifier.verify(destinationURL: delivery, deep: deep)
            XCTAssertTrue(report.passed, report.issues.joined(separator: "\n"))
            XCTAssertEqual(report.checkedArchives, 2)
        }
        do {
            let destination = try Destination(url: delivery)
            XCTAssertFalse(destination.info.writable)
            let hash = try ZIPArchive.hash(name: firstName, destination: destination, cancellation: CancellationToken()) { _ in }
            XCTAssertEqual(hash.sha256, job.archives[0].sha256)
            XCTAssertNoThrow(try ZIPArchive.verify(name: firstName, files: job.archives[0].plan.files,
                                                   destination: destination, cancellation: CancellationToken()) { _, _ in })
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let amount = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard amount > 0 else { throw HandoffError.io("Cannot write disposable fixture bytes.") }
                written += amount
            }
        }
    }

    private func hdiutil(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
