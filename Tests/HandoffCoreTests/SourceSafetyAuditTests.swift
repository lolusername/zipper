import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

final class SourceSafetyAuditTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-source-safety-audit-\(UUID().uuidString)")
        var source: URL { root.appendingPathComponent("source") }
        var destination: URL { root.appendingPathComponent("destination") }
        var removeAtDeinit = true
        init() throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        deinit { if removeAtDeinit { try? FileManager.default.removeItem(at: root) } }
        func clip(in directory: URL? = nil) throws {
            let base = directory ?? source
            // POSIX fixture creation avoids Foundation provenance xattrs generating AppleDouble
            // files on FAT/exFAT, which the intentionally strict source inventory would block.
            for (name, data) in [("A001.mov", Data(repeating: 0x31, count: 8192)), ("A001.xml", Data("<clip/>".utf8))] {
                let fd = Darwin.open(base.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw HandoffError.io("Cannot create disposable source fixture.") }
                let amount = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                _ = fsync(fd)
                Darwin.close(fd)
                guard amount == data.count else { throw HandoffError.io("Cannot populate disposable source fixture.") }
                _ = removexattr(base.appendingPathComponent(name).path, "com.apple.provenance", 0)
            }
            try removeFixtureMetadata(in: base)
        }
        func removeFixtureMetadata(in base: URL) throws {
            // Remove OS-created provenance sidecars from this newly manufactured fixture only.
            let directory = Darwin.open(base.path, O_RDONLY | O_DIRECTORY)
            guard directory >= 0 else { throw HandoffError.io("Cannot inspect disposable fixture metadata.") }
            defer { Darwin.close(directory) }
            for name in try directoryNames(directory) where name.hasPrefix("._") {
                guard unlinkat(directory, name, 0) == 0 else { throw HandoffError.io("Cannot remove generated fixture metadata.") }
            }
        }
    }

    func testEveryObservedSourceDescriptorIsReadOnly() throws {
        let fixture = try Fixture(); try fixture.clip()
        let source = try ReadOnlySource(url: fixture.source)
        let media = try source.scan().first { $0.kind == .media }!
        var observed = 0
        try source.stream(media, cancellation: CancellationToken()) { _ in
            for descriptor in Int32(0)..<Int32(min(getdtablesize(), 4096)) {
                var status = stat()
                if fstat(descriptor, &status) == 0, sameObject(fileIdentity(status), media.identity) {
                    let flags = fcntl(descriptor, F_GETFL)
                    XCTAssertGreaterThanOrEqual(flags, 0)
                    XCTAssertEqual(flags & O_ACCMODE, O_RDONLY, "Source inode unexpectedly has a writable descriptor.")
                    observed += 1
                }
            }
        }
        XCTAssertGreaterThan(observed, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent(media.relativePath)), Data(repeating: 0x31, count: 8192))
    }

    func testDestinationAncestorSymlinkReplacementCannotRedirectCreationIntoSource() throws {
        let fixture = try Fixture(); try fixture.clip()
        let route = fixture.root.appendingPathComponent("route")
        let output = route.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try ReadOnlySource(url: fixture.source)
        let original = try source.scan()
        let destination = try Destination(url: output, source: source)
        try FileManager.default.moveItem(at: route, to: fixture.root.appendingPathComponent("retained-route"))
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try destination.createExclusive("NEW.mov"))
        XCTAssertThrowsError(try destination.writeAtomic(Data([9]), name: "HANDOFF_MANIFEST.txt", replace: false))
        XCTAssertEqual(try source.scan(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("NEW.mov").path))
    }

    func testAPFSSameSizeRewriteWithRestoredMtimeIsDetectedDuringHash() throws {
        let fixture = try Fixture(); try fixture.clip()
        let source = try ReadOnlySource(url: fixture.source)
        let media = try source.scan().first { $0.kind == .media }!
        var changed = false
        XCTAssertThrowsError(try source.hash(media, cancellation: CancellationToken()) { _ in
            guard !changed else { return }; changed = true
            do { try self.rewriteFirstBytePreservingTimes(fixture.source.appendingPathComponent(media.relativePath)) }
            catch { XCTFail("Fixture mutation failed: \(error)") }
        })
        XCTAssertTrue(changed)
    }

    func testNetworkAndUnknownSourceFilesystemsFailClosedEvenIfMountedReadOnly() throws {
        for filesystem in ["nfs", "smbfs", "webdav", "afpfs", "unknown"] {
            XCTAssertThrowsError(try SourceFilesystemPolicy.validate(filesystem: filesystem, isReadOnly: true))
            XCTAssertThrowsError(try SourceFilesystemPolicy.validate(filesystem: filesystem, isReadOnly: false))
        }
        XCTAssertNoThrow(try SourceFilesystemPolicy.validate(filesystem: "apfs", isReadOnly: false))
    }

    func testWritableFAT32SourceRequiresReadOnlyMountBeforePreflightOrHashing() throws {
        try assertWritableSourceRejected(filesystem: "MS-DOS FAT32")
    }

    func testWritableExFATSourceRequiresReadOnlyMountBeforePreflightOrHashing() throws {
        try assertWritableSourceRejected(filesystem: "ExFAT")
    }

    func testWritableHFSSourceRequiresReadOnlyMountBeforePreflightOrHashing() throws {
        try assertWritableSourceRejected(filesystem: "HFS+")
    }

    // Before the source-filesystem gate, writable FAT32 returned a successful source hash
    // after a same-size rewrite during hashing. HFS+ returned a completed job and passing
    // source-free deep check after such a source rewrite at the report-publication callback.
    // These regression checks require rejection before content reads or output creation.
    private func assertWritableSourceRejected(filesystem: String) throws {
        try withDisposableSourceVolume(filesystem: filesystem) { fixture, sourceURL in
            try fixture.clip(in: sourceURL)
            let path = sourceURL.appendingPathComponent("A001.mov")
            _ = chmod(path.path, 0o444)
            _ = chmod(sourceURL.path, 0o555)
            let source = try ReadOnlySource(url: sourceURL) // Identity-only inspection remains available for export isolation.
            var status = stat()
            XCTAssertEqual(lstat(path.path, &status), 0)
            let media = SourceFile(relativePath: "A001.mov", basename: "A001", kind: .media, identity: fileIdentity(status))
            XCTAssertThrowsError(try source.scan()) { XCTAssertTrue($0.localizedDescription.contains("mounted read-only")) }
            XCTAssertThrowsError(try source.validate(media))
            var consumed = false
            XCTAssertThrowsError(try source.stream(media, cancellation: CancellationToken()) { _ in consumed = true })
            XCTAssertThrowsError(try source.hash(media, cancellation: CancellationToken()) { _ in consumed = true })
            XCTAssertFalse(consumed)
            let configuration = JobConfiguration(sourcePath: sourceURL.path, destinationPath: fixture.destination.path)
            XCTAssertThrowsError(try Preflight.analyze(configuration)) { XCTAssertTrue($0.localizedDescription.contains("mounted read-only")) }
            XCTAssertThrowsError(try Destination(url: sourceURL, source: source))
            XCTAssertEqual(try Destination(url: fixture.destination, source: source).names(), [])

            let unsafeDestination = try Destination(url: sourceURL)
            let beforeNames = try unsafeDestination.names()
            XCTAssertThrowsError(try unsafeDestination.validateIntegrityReadSafety())
            XCTAssertThrowsError(try unsafeDestination.createExclusive("NEW.partial")) { XCTAssertTrue($0.localizedDescription.contains("writable local APFS")) }
            XCTAssertThrowsError(try unsafeDestination.renameExclusive(from: "A001.mov", to: "MOVED.mov"))
            XCTAssertThrowsError(try unsafeDestination.writeAtomic(Data([1]), name: "REPORT.txt", replace: false))
            XCTAssertEqual(try unsafeDestination.names(), beforeNames)
            try fixture.clip() // A safe APFS source, with this image selected as output.
            let outputReport = try Preflight.analyze(JobConfiguration(sourcePath: fixture.source.path, destinationPath: sourceURL.path))
            XCTAssertFalse(outputReport.canCreate)
            XCTAssertTrue(outputReport.issues.contains { $0.contains("writable local APFS") })
        }
    }

    func testReadOnlyFAT32SourceCompletesVerifiedHandoff() throws { try assertReadOnlySourceCompletes(filesystem: "MS-DOS FAT32") }
    func testReadOnlyExFATSourceCompletesVerifiedHandoff() throws { try assertReadOnlySourceCompletes(filesystem: "ExFAT") }
    func testReadOnlyHFSSourceCompletesVerifiedHandoff() throws { try assertReadOnlySourceCompletes(filesystem: "HFS+") }

    private func assertReadOnlySourceCompletes(filesystem: String) throws {
        try withDisposableSourceVolume(filesystem: filesystem) { fixture, sourceURL in
            try fixture.clip(in: sourceURL)
            let mount = sourceURL.deletingLastPathComponent()
            let detached = try hdiutil(["detach", mount.path])
            guard detached.0 == 0 else { throw HandoffError.io("Cannot detach disposable image for read-only test: \(detached.1)") }
            let attached = try hdiutil(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, fixture.root.appendingPathComponent("source-fat32.dmg").path])
            guard attached.0 == 0 else { throw HandoffError.io("Cannot remount disposable source image read-only: \(attached.1)") }
            let writeAttempt = Darwin.open(sourceURL.appendingPathComponent("A001.mov").path, O_WRONLY | O_NOFOLLOW)
            XCTAssertLessThan(writeAttempt, 0, "The fixture must be OS-mounted read-only.")
            if writeAttempt >= 0 { Darwin.close(writeAttempt) }
            let source = try ReadOnlySource(url: sourceURL)
            XCTAssertNoThrow(try Destination(url: sourceURL).validateIntegrityReadSafety())
            XCTAssertThrowsError(try Destination(url: sourceURL).validateWriteSafety())
            let before = try source.scan()
            let configuration = JobConfiguration(sourcePath: sourceURL.path, destinationPath: fixture.destination.path)
            let report = try Preflight.analyze(configuration)
            XCTAssertTrue(report.canCreate, report.issues.joined(separator: "\n"))
            let job = try JobEngine().create(preflight: report)
            XCTAssertEqual(job.status, .completed)
            XCTAssertTrue(job.finalSourceVerified)
            XCTAssertEqual(job.preflight.files.count, 2)
            XCTAssertEqual(try source.scan(), before)
            XCTAssertTrue(try HandoffVerifier.verify(destinationURL: fixture.destination, deep: true).passed)
        }
    }

    private func withDisposableSourceVolume(filesystem: String, body: (Fixture, URL) throws -> Void) throws {
        guard ProcessInfo.processInfo.environment["ZIPPER_RUN_SOURCE_SAFETY_VOLUME_TESTS"] == "1" ||
              ProcessInfo.processInfo.environment["ZIPPER_RUN_FILESYSTEM_TESTS"] == "1" else {
            throw XCTSkip("Opt-in source-card metadata audit; creates only disposable FAT32/exFAT/HFS+ images.")
        }
        let fixture = try Fixture()
        let image = fixture.root.appendingPathComponent("source-fat32.dmg")
        let mount = fixture.root.appendingPathComponent("source-card")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let creation = try hdiutil(["create", "-size", "128m", "-fs", filesystem, "-volname", "ZIPPERAUDIT", "-type", "UDIF", "-layout", "NONE", image.path])
        guard creation.0 == 0 else { throw HandoffError.io("Disposable source image creation failed: \(creation.1)") }
        let attachment = try hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        guard attachment.0 == 0 else { throw HandoffError.io("Disposable source image attachment failed: \(attachment.1)") }
        defer {
            do {
                var result = try hdiutil(["detach", mount.path])
                if result.0 != 0 { result = try hdiutil(["detach", "-force", mount.path]) }
                if result.0 != 0 { fixture.removeAtDeinit = false }
                XCTAssertEqual(result.0, 0, "Disposable image retained at \(fixture.root.path): \(result.1)")
            } catch {
                fixture.removeAtDeinit = false
                XCTFail("Could not detach disposable image; retained \(fixture.root.path): \(error)")
            }
        }
        let sourceURL = mount.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
        try body(fixture, sourceURL)
    }

    private func rewriteFirstBytePreservingTimes(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HandoffError.io("Cannot mutate disposable audit fixture.") }
        defer { Darwin.close(descriptor) }
        try rewriteFirstBytePreservingTimes(descriptor)
    }

    private func rewriteFirstBytePreservingTimes(_ descriptor: Int32) throws {
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw HandoffError.io("Cannot inspect disposable audit fixture.") }
        var byte: UInt8 = 0xFF
        guard pwrite(descriptor, &byte, 1, 0) == 1 else { throw HandoffError.io("Cannot rewrite disposable audit fixture.") }
        var times = [original.st_atimespec, original.st_mtimespec]
        guard futimens(descriptor, &times) == 0, fsync(descriptor) == 0 else { throw HandoffError.io("Cannot restore disposable audit fixture timestamps.") }
    }

    private func hdiutil(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
