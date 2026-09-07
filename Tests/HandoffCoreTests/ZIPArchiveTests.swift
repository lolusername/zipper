import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

final class ZIPArchiveTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let sourceURL: URL
        let destinationURL: URL
        let source: ReadOnlySource
        let destination: Destination
        let plan: ArchivePlan
        init(payload: Data = Data((0..<2_100_123).map { UInt8(truncatingIfNeeded: $0) }), basename: String = "Café_001", sparseSize: UInt64? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-zip-tests-\(UUID().uuidString)")
            sourceURL = root.appendingPathComponent("source")
            destinationURL = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let mediaURL = sourceURL.appendingPathComponent("\(basename).mov")
            if let sparseSize {
                let fd = Darwin.open(mediaURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw HandoffError.io("Cannot create large fixture.") }
                guard ftruncate(fd, off_t(sparseSize)) == 0 else { Darwin.close(fd); throw HandoffError.io("Cannot size large fixture.") }
                Darwin.close(fd)
            } else { try payload.write(to: mediaURL) }
            try Data("<clip name=\"\(basename)\"/>".utf8).write(to: sourceURL.appendingPathComponent("\(basename).xml"))
            source = try ReadOnlySource(url: sourceURL)
            destination = try Destination(url: destinationURL, source: source)
            let sourceReader = source
            let files = try sourceReader.scan().map { original -> SourceFile in
                var file = original
                file.sha256 = try sourceReader.hash(file, cancellation: CancellationToken()) { _ in }
                return file
            }
            let package = ClipPackage(basename: basename, media: files.first { $0.kind == .media }!, xml: files.first { $0.kind == .xml }!)
            plan = ArchivePlan(name: "FOOTAGE_001.zip", packages: [package], predictedBytes: ZIPArchive.predictedSize(files: package.files))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        @discardableResult func write(_ name: String = ".FOOTAGE_001.zip.partial", cancellation: CancellationToken = CancellationToken(), progress: (String, UInt64) throws -> Void = { _, _ in }) throws -> UInt64 {
            try ZIPArchive.write(plan: plan, source: source, destination: destination, partialName: name, cancellation: cancellation, progress: progress)
        }
        func verify(_ name: String = ".FOOTAGE_001.zip.partial", files: [SourceFile]? = nil, cancellation: CancellationToken = CancellationToken()) throws {
            try ZIPArchive.verify(name: name, files: files ?? plan.files, destination: destination, cancellation: cancellation) { _, _ in }
        }
        func read(_ name: String = ".FOOTAGE_001.zip.partial") throws -> Data { try Data(contentsOf: destinationURL.appendingPathComponent(name)) }
        func corrupt(_ mutation: (inout Data) -> Void) throws {
            var bytes = try read()
            mutation(&bytes)
            try bytes.write(to: destinationURL.appendingPathComponent(".FOOTAGE_001.zip.partial"))
        }
    }

    func testExactSizeDeterministicBytesIndependentReaderAndUnzip() throws {
        let fixture = try Fixture()
        var written: UInt64 = 0
        XCTAssertEqual(try fixture.write(progress: { _, count in written += count }), fixture.plan.predictedBytes)
        XCTAssertEqual(written, fixture.plan.predictedBytes)
        try fixture.verify()
        var read: UInt64 = 0
        let hash = try ZIPArchive.hash(name: ".FOOTAGE_001.zip.partial", destination: fixture.destination, cancellation: CancellationToken()) { read += $0 }
        let bytes = try fixture.read()
        XCTAssertEqual(read, fixture.plan.predictedBytes)
        XCTAssertEqual(hash.bytes, fixture.plan.predictedBytes)
        XCTAssertEqual(hash.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try fixture.write(".SECOND.zip.partial")
        XCTAssertEqual(bytes, try fixture.read(".SECOND.zip.partial"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", fixture.destinationURL.appendingPathComponent(".FOOTAGE_001.zip.partial").path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, report)
        XCTAssertTrue(report.contains("No errors detected"), report)
    }

    func testWriterReportsSourceBytesSeparatelyFromZIPOverhead() throws {
        let fixture = try Fixture(payload: Data(repeating: 7, count: 2_100_000))
        var sourceBytes: UInt64 = 0
        var outputBytes: UInt64 = 0
        _ = try ZIPArchive.write(plan: fixture.plan, source: fixture.source, destination: fixture.destination,
                             partialName: ".FOOTAGE_001.zip.partial", cancellation: CancellationToken(),
                             sourceProgress: { _, bytes in sourceBytes += bytes }) { _, bytes in outputBytes += bytes }
        XCTAssertEqual(sourceBytes, fixture.plan.files.reduce(0) { $0 + $1.size })
        XCTAssertEqual(outputBytes, fixture.plan.predictedBytes)
        XCTAssertGreaterThan(outputBytes, sourceBytes)
    }

    func testEmptyMediaAndChunkBoundaryPayloads() throws {
        for size in [0, 1, 1_048_576, 4_194_303, 4_194_304, 4_194_305] {
            let fixture = try Fixture(payload: Data(repeating: 0xAE, count: size), basename: "A001")
            XCTAssertEqual(try fixture.write(), fixture.plan.predictedBytes)
            try fixture.verify()
        }
    }

    func testPayloadCorruptionFailsCryptographicVerification() throws {
        let fixture = try Fixture()
        try fixture.write()
        try fixture.corrupt { bytes in
            let payload = 50 + fixture.plan.files[0].relativePath.utf8.count
            bytes[payload + 17] ^= 0x80
        }
        XCTAssertThrowsError(try fixture.verify())
    }

    func testMissingTruncatedAndAlteredCentralDirectoryAreRejected() throws {
        let fixture = try Fixture(payload: Data(repeating: 42, count: 37))
        try fixture.write()
        let original = try fixture.read()
        let path = fixture.destinationURL.appendingPathComponent(".FOOTAGE_001.zip.partial")
        for missing in [1, 22, 98, 120] {
            try original.dropLast(missing).write(to: path)
            XCTAssertThrowsError(try fixture.verify(), "Must reject truncating \(missing) bytes")
        }
        try original.write(to: path)
        try fixture.corrupt { bytes in bytes[bytes.count - 30] ^= 1 }
        XCTAssertThrowsError(try fixture.verify())
        try original.write(to: path)
        try fixture.corrupt { bytes in bytes.append(0) }
        XCTAssertThrowsError(try fixture.verify())
        try original.write(to: path)
        let directoryOffset = fixture.plan.files.reduce(0) { $0 + 74 + $1.relativePath.utf8.count + Int($1.size) }
        try fixture.corrupt { bytes in bytes[directoryOffset + 46] ^= 1 }
        XCTAssertThrowsError(try fixture.verify())
    }

    func testConsistentlyAlteredCRCStillFailsIndependentReader() throws {
        let fixture = try Fixture(payload: Data(repeating: 7, count: 121))
        try fixture.write()
        let first = fixture.plan.files[0]
        let descriptorOffset = 50 + first.relativePath.utf8.count + Int(first.size)
        let directoryOffset = fixture.plan.files.reduce(0) { $0 + 74 + $1.relativePath.utf8.count + Int($1.size) }
        try fixture.corrupt { bytes in
            bytes[descriptorOffset + 4] ^= 1
            bytes[directoryOffset + 16] ^= 1
        }
        XCTAssertThrowsError(try fixture.verify())
    }

    func testArchiveReplacementDuringHashFailsNamedIdentityCheck() throws {
        let fixture = try Fixture(payload: Data(repeating: 7, count: 2_100_000))
        try fixture.write()
        let path = fixture.destinationURL.appendingPathComponent(".FOOTAGE_001.zip.partial")
        var replaced = false
        XCTAssertThrowsError(try ZIPArchive.hash(name: ".FOOTAGE_001.zip.partial", destination: fixture.destination, cancellation: CancellationToken()) { _ in
            if !replaced {
                replaced = true
                try FileManager.default.moveItem(at: path, to: fixture.destinationURL.appendingPathComponent(".original.partial"))
                try Data(repeating: 0, count: Int(fixture.plan.predictedBytes)).write(to: path)
            }
        })
        XCTAssertTrue(replaced)
    }

    func testWrongExpectedNamesCountsAndHashesAreRejected() throws {
        let fixture = try Fixture(payload: Data([1, 2, 3]))
        try fixture.write()
        var files = fixture.plan.files
        files[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try fixture.verify(files: files))
        files = fixture.plan.files
        files[0].relativePath = "../escape.mov"
        XCTAssertThrowsError(try fixture.verify(files: files))
        XCTAssertThrowsError(try fixture.verify(files: [fixture.plan.files[0]]))
        XCTAssertThrowsError(try fixture.verify(files: fixture.plan.files + fixture.plan.files))
    }

    func testCancellationRetainsOnlyPartialAndDoesNotChangeSource() throws {
        let fixture = try Fixture(payload: Data(repeating: 5, count: 5_000_000))
        let before = try fixture.source.scan()
        let cancellation = CancellationToken()
        XCTAssertThrowsError(try fixture.write(cancellation: cancellation, progress: { _, count in
            if count > 1_048_576 { cancellation.cancel() }
        })) { error in XCTAssertEqual(error as? HandoffError, .cancelled) }
        XCTAssertEqual(try fixture.destination.names(), [".FOOTAGE_001.zip.partial"])
        XCTAssertLessThan(try fixture.read().count, Int(fixture.plan.predictedBytes))
        XCTAssertEqual(try fixture.source.scan(), before)
        for file in fixture.plan.files {
            XCTAssertEqual(try fixture.source.hash(file, cancellation: CancellationToken()) { _ in }, file.sha256)
        }
        XCTAssertThrowsError(try fixture.verify(cancellation: cancellation)) { error in XCTAssertEqual(error as? HandoffError, .cancelled) }
    }

    func testSourceHashMismatchFailsAndExclusiveCreationPreservesOutput() throws {
        let fixture = try Fixture(payload: Data(repeating: 9, count: 1024))
        try fixture.write()
        let original = try fixture.read()
        XCTAssertThrowsError(try fixture.write())
        XCTAssertEqual(try fixture.read(), original)
        var plan = fixture.plan
        plan.packages[0].media.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ZIPArchive.write(plan: plan, source: fixture.source, destination: fixture.destination, partialName: ".BAD.zip.partial", cancellation: CancellationToken()) { _, _ in })
        XCTAssertFalse(try fixture.destination.names().contains("BAD.zip"))
    }

    func testUnapprovedSizeRejectedBeforeAnyWrite() throws {
        let fixture = try Fixture(payload: Data([1]))
        var plan = fixture.plan
        plan.predictedBytes -= 1
        XCTAssertThrowsError(try ZIPArchive.write(plan: plan, source: fixture.source, destination: fixture.destination, partialName: ".BAD.zip.partial", cancellation: CancellationToken()) { _, _ in })
        XCTAssertEqual(try fixture.destination.names(), [])
    }

    func testZIP64SizeAndEntryCountBoundaryArithmetic() throws {
        var file = SourceFile(relativePath: "A.mov", basename: "A", kind: .media,
                              identity: FileIdentity(device: 0, inode: 0, size: 0, modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0))
        for size in [UInt64(0), UInt64(UInt32.max) - 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, 1_000_000_000_000] {
            file.identity.size = size
            XCTAssertEqual(ZIPArchive.predictedSize(files: [file]), size + 256)
        }
        file.identity.size = 0
        XCTAssertEqual(ZIPArchive.predictedSize(files: Array(repeating: file, count: 65_536)), 98 + 65_536 * 158)
        file.identity.size = UInt64.max
        XCTAssertEqual(ZIPArchive.predictedSize(files: [file]), UInt64.max)
        XCTAssertEqual(ZIPArchive.predictedSize(files: [file, file]), UInt64.max)
    }

    func testRealZIP64OverFourGiB() throws {
        guard ProcessInfo.processInfo.environment["ZIPPER_RUN_LARGE_ZIP_TESTS"] == "1" else {
            throw XCTSkip("Opt-in streaming test writes a 4 GiB ZIP; set ZIPPER_RUN_LARGE_ZIP_TESTS=1.")
        }
        let fixture = try Fixture(payload: Data(), basename: "BIG", sparseSize: UInt64(UInt32.max) + 17)
        XCTAssertGreaterThan(fixture.plan.predictedBytes, UInt64(UInt32.max))
        XCTAssertEqual(try fixture.write(), fixture.plan.predictedBytes)
        try fixture.verify()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", fixture.destinationURL.appendingPathComponent(".FOOTAGE_001.zip.partial").path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, report)
    }
}
