import XCTest
import Foundation
import Darwin
@testable import HandoffCore

/// Real macOS filesystem checks against a newly created disposable disk image only.
/// Run: ZIPPER_RUN_FILESYSTEM_TESTS=1 swift test --filter FilesystemVolumeTests
final class FilesystemVolumeTests: XCTestCase {
    private func run(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    func testRealFAT32FileLimitAndCapacityPreflightWithoutWrites() throws {
        guard ProcessInfo.processInfo.environment["ZIPPER_RUN_FILESYSTEM_TESTS"] == "1" else {
            throw XCTSkip("Opt-in disposable 128 MiB FAT32 volume test; set ZIPPER_RUN_FILESYSTEM_TESTS=1. No real drives are detached.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-filesystem-tests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let mount = root.appendingPathComponent("mount")
        let image = root.appendingPathComponent("fat32.dmg")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        var attached = false
        defer {
            if attached {
                do {
                    let detached = try run(["detach", mount.path])
                    XCTAssertEqual(detached.0, 0, "Could not detach disposable image: \(detached.1). Image retained at \(root.path).")
                    if detached.0 == 0 { try? FileManager.default.removeItem(at: root) }
                } catch { XCTFail("Could not detach disposable image: \(error). Image retained at \(root.path).") }
            } else { try? FileManager.default.removeItem(at: root) }
        }
        let creation = try run(["create", "-size", "128m", "-fs", "MS-DOS FAT32", "-volname", "ZIPPERTEST", "-type", "UDIF", "-layout", "NONE", image.path])
        guard creation.0 == 0 else {
            if permissionDenied(creation.1) { throw XCTSkip("macOS did not permit creating a disposable FAT32 image: \(creation.1)") }
            throw HandoffError.io("Disposable FAT32 image creation failed: \(creation.1)")
        }
        let attachment = try run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        guard attachment.0 == 0 else {
            if permissionDenied(attachment.1) { throw XCTSkip("macOS did not permit attaching the disposable FAT32 image: \(attachment.1)") }
            throw HandoffError.io("Disposable FAT32 image attachment failed: \(attachment.1)")
        }
        attached = true
        // Use a clean child directory because macOS may create its own volume-root system files.
        let destination = mount.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let media = source.appendingPathComponent("BIG.mov")
        let descriptor = Darwin.open(media.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw HandoffError.io("Cannot create disposable sparse source fixture.") }
        guard ftruncate(descriptor, 25_000_000_000) == 0 else { Darwin.close(descriptor); throw HandoffError.io("Cannot size disposable sparse source fixture.") }
        Darwin.close(descriptor)
        try Data("<clip/>".utf8).write(to: source.appendingPathComponent("BIG.xml"))
        let config = JobConfiguration(sourcePath: source.path, destinationPath: destination.path, mode: .archiveCount(1))
        let large = try Preflight.analyze(config)
        XCTAssertEqual(large.destination.filesystem.lowercased(), "msdos")
        XCTAssertEqual(large.destination.maxFileBytes, UInt64(UInt32.max))
        XCTAssertFalse(large.canCreate)
        XCTAssertTrue(large.issues.contains { $0.contains("cannot hold") && $0.contains("FOOTAGE_001.zip") }, large.issues.joined(separator: "\n"))
        XCTAssertTrue(large.issues.contains { $0.contains("Insufficient destination capacity") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try ReadOnlySource(url: source).scan().first { $0.kind == .media }?.size, 25_000_000_000)

        let resize = Darwin.open(media.path, O_WRONLY | O_NOFOLLOW)
        guard resize >= 0 else { throw HandoffError.io("Cannot resize disposable source fixture.") }
        guard ftruncate(resize, 80 * 1024 * 1024) == 0 else { Darwin.close(resize); throw HandoffError.io("Cannot resize disposable source fixture.") }
        Darwin.close(resize)
        let capacity = try Preflight.analyze(config)
        XCTAssertLessThan(capacity.archives[0].predictedBytes, UInt64(UInt32.max))
        XCTAssertLessThan(capacity.archives[0].predictedBytes, capacity.destination.availableBytes)
        XCTAssertGreaterThan(capacity.requiredBytes, capacity.destination.availableBytes)
        XCTAssertFalse(capacity.canCreate)
        XCTAssertFalse(capacity.issues.contains { $0.contains("cannot hold") })
        XCTAssertTrue(capacity.issues.contains { $0.contains("Insufficient destination capacity") }, capacity.issues.joined(separator: "\n"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    private func permissionDenied(_ output: String) -> Bool {
        ["not permitted", "permission denied", "authorization", "not authorized", "access denied"].contains { output.lowercased().contains($0) }
    }
}
