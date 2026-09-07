import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

final class SourcePreflightTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-source-tests-\(UUID().uuidString)")
        var source: URL { root.appendingPathComponent("source") }
        var destination: URL { root.appendingPathComponent("destination") }
        init() throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func clip(_ name: String = "A001", size: Int = 1000) throws {
            try Data(repeating: UInt8(size % 255), count: size).write(to: source.appendingPathComponent("\(name).mov"))
            try Data("<clip id=\"\(name)\"/>".utf8).write(to: source.appendingPathComponent("\(name).xml"))
        }
        func config(mode: BatchingMode = .maximumBytes(25_000_000_000), acknowledged: Bool = false) -> JobConfiguration {
            JobConfiguration(sourcePath: source.path, destinationPath: destination.path, mode: mode, acknowledgedOversized: acknowledged)
        }
        func snapshot(_ directory: URL) throws -> [String: String] {
            var result: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in enumerator {
                let path = String(url.path.dropFirst(directory.path.count + 1))
                let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                if regular {
                    let bytes = try Data(contentsOf: url)
                    result[path] = "\(bytes.count):" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                } else { result[path] = "directory-or-link" }
            }
            return result
        }
    }

    func testPreflightHasZeroSourceAndDestinationWrites() throws {
        let f = try Fixture(); try f.clip(); try f.clip("B002", size: 5000)
        let beforeSource = try f.snapshot(f.source)
        let beforeDestination = try f.snapshot(f.destination)
        let source = try ReadOnlySource(url: f.source)
        let beforeIdentity = source.identity
        let report = try Preflight.analyze(f.config())
        XCTAssertTrue(report.canCreate, report.issues.joined(separator: "\n"))
        XCTAssertEqual(report.packages.count, 2)
        XCTAssertEqual(report.files.count, 4)
        XCTAssertEqual(beforeSource, try f.snapshot(f.source))
        XCTAssertEqual(beforeDestination, try f.snapshot(f.destination))
        XCTAssertEqual(beforeIdentity, try ReadOnlySource(url: f.source).identity)
        XCTAssertGreaterThanOrEqual(report.requiredBytes, report.archives[0].predictedBytes + 64 * 1024 * 1024)
    }

    func testUnknownHiddenNestedAndSymlinkEntriesAreVisibleAndBlock() throws {
        let f = try Fixture(); try f.clip()
        try Data([1]).write(to: f.source.appendingPathComponent("camera.database"))
        try Data([2]).write(to: f.source.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: f.source.appendingPathComponent("DCIM"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked.mov"), withDestinationURL: f.source.appendingPathComponent("A001.mov"))
        let before = try f.snapshot(f.source)
        let report = try Preflight.analyze(f.config())
        XCTAssertFalse(report.canCreate)
        XCTAssertEqual(report.files.count, 6)
        XCTAssertTrue(report.files.contains { $0.kind == .unexpected })
        XCTAssertTrue(report.files.contains { $0.kind == .hidden })
        XCTAssertTrue(report.files.contains { $0.kind == .directory })
        XCTAssertTrue(report.files.contains { $0.kind == .symlink })
        XCTAssertGreaterThanOrEqual(report.issues.count, 4)
        XCTAssertEqual(try f.snapshot(f.source), before)
        XCTAssertEqual(try f.snapshot(f.destination), [:])
    }

    func testMissingAndAmbiguousPairingBlocks() throws {
        let f = try Fixture(); try f.clip()
        try Data([1]).write(to: f.source.appendingPathComponent("A001.mxf"))
        try Data([2]).write(to: f.source.appendingPathComponent("NO_XML.mov"))
        try Data([3]).write(to: f.source.appendingPathComponent("NO_MEDIA.xml"))
        let report = try Preflight.analyze(f.config())
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.issues.contains { $0.contains("Duplicate/ambiguous") })
        XCTAssertTrue(report.issues.contains { $0.contains("Missing XML") })
        XCTAssertTrue(report.issues.contains { $0.contains("Missing media") })
        XCTAssertTrue(report.packages.isEmpty)
    }

    func testCaseMismatchBetweenMediaAndSidecarBlocks() throws {
        let f = try Fixture()
        try Data([1]).write(to: f.source.appendingPathComponent("CLIP.mov"))
        try Data([2]).write(to: f.source.appendingPathComponent("clip.xml"))
        let report = try Preflight.analyze(f.config())
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.issues.contains { $0.contains("basenames must match exactly") })
        XCTAssertEqual(collisionKey("Café.MOV"), collisionKey("CAFE\u{301}.mov"))
    }

    func testPathSymlinkAndAncestryOverlapAreRejected() throws {
        let f = try Fixture(); try f.clip()
        let source = try ReadOnlySource(url: f.source)
        XCTAssertThrowsError(try Destination(url: f.source, source: source))
        XCTAssertThrowsError(try Destination(url: f.root, source: source))
        let nested = f.source.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let fresh = try ReadOnlySource(url: f.source)
        XCTAssertThrowsError(try Destination(url: nested, source: fresh))
        let link = f.root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        XCTAssertThrowsError(try Destination(url: link, source: fresh))
        XCTAssertEqual(try ReadOnlySource(url: link).canonicalPath, fresh.canonicalPath)
        XCTAssertThrowsError(try Destination(url: f.source.appendingPathComponent("../source"), source: fresh))
    }

    func testFinderAliasCanonicalizationBlocksOverlap() throws {
        let f = try Fixture(); try f.clip()
        let bookmark = try f.source.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
        let alias = f.root.appendingPathComponent("Source Alias")
        try URL.writeBookmarkData(bookmark, to: alias)
        let source = try ReadOnlySource(url: f.source)
        XCTAssertEqual(try ReadOnlySource(url: alias).canonicalPath, source.canonicalPath)
        XCTAssertThrowsError(try Destination(url: alias, source: source))
    }

    func testDisjointSelectionsDoNotOpenUnselectedUnreadableParents() throws {
        guard getuid() != 0 else { throw XCTSkip("Read-permission boundary test requires a non-root account.") }
        let f = try Fixture(); try f.clip()
        let similarlyNamed = f.root.appendingPathComponent("source-delivery")
        try FileManager.default.createDirectory(at: similarlyNamed, withIntermediateDirectories: false)
        // Selected children remain readable/searchable. The parent is searchable but cannot
        // be opened O_RDONLY, reproducing the boundary that unbounded '..' traversal crossed.
        XCTAssertEqual(chmod(f.root.path, mode_t(0o111)), 0)
        defer { _ = chmod(f.root.path, mode_t(0o700)) }
        let parent = Darwin.open(f.root.path, O_RDONLY | O_DIRECTORY)
        if parent >= 0 { Darwin.close(parent); throw XCTSkip("This account bypasses the parent directory read boundary.") }
        XCTAssertTrue(try Preflight.analyze(f.config()).canCreate)
        let source = try ReadOnlySource(url: f.source)
        XCTAssertNoThrow(try Destination(url: similarlyNamed, source: source))
    }

    func testKernelCanonicalPathsRetainFirmlinkAndNestedOverlapProtection() throws {
        let f = try Fixture(); try f.clip()
        let nested = f.source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let source = try ReadOnlySource(url: f.source)
        let descriptor = Darwin.open(source.canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HandoffError.io("Cannot open source fixture descriptor.") }
        defer { Darwin.close(descriptor) }
        let kernelPath = try descriptorPath(descriptor)
        XCTAssertThrowsError(try Destination(url: URL(fileURLWithPath: kernelPath), source: source))
        XCTAssertThrowsError(try Destination(url: URL(fileURLWithPath: kernelPath).appendingPathComponent("nested"), source: source))
        let selectedNested = try ReadOnlySource(url: nested)
        XCTAssertThrowsError(try Destination(url: URL(fileURLWithPath: kernelPath), source: selectedNested))
    }

    func testExpectedOutputCaseInsensitiveAndPendingCollisionsBlockWithoutWriting() throws {
        for name in ["footage_001.ZIP", ".footage_001.zip.partial", "handoff_manifest.JSON", ".zipper-job.lock", "..zipper-job.json.pending", ".HANDOFF_MANIFEST.txt.pending"] {
            let f = try Fixture(); try f.clip()
            try Data("existing delivery".utf8).write(to: f.destination.appendingPathComponent(name))
            let before = try f.snapshot(f.destination)
            let report = try Preflight.analyze(f.config())
            XCTAssertFalse(report.canCreate, name)
            XCTAssertTrue(report.issues.contains { $0.contains("Output collision") }, name)
            XCTAssertEqual(try f.snapshot(f.destination), before)
        }
    }

    func testUnrelatedZIPBlocksBeforePackagingWhileUnreservedTextIsAllowed() throws {
        let f = try Fixture(); try f.clip()
        try Data("delivery instructions".utf8).write(to: f.destination.appendingPathComponent("README.txt"))
        XCTAssertTrue(try Preflight.analyze(f.config()).canCreate)
        try Data("unrelated archive".utf8).write(to: f.destination.appendingPathComponent("OTHER_CLIENT.ZIP"))
        let before = try f.snapshot(f.destination)
        let report = try Preflight.analyze(f.config())
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.issues.contains { $0.contains("Unrelated ZIP") && $0.contains("OTHER_CLIENT.ZIP") })
        XCTAssertEqual(try f.snapshot(f.destination), before)
    }

    func testMaximumIsExactZIPCeilingAndOversizedNeedsAcknowledgment() throws {
        let f = try Fixture(); try f.clip("A001", size: 1000); try f.clip("A002", size: 1000)
        let initial = try Preflight.analyze(f.config())
        let ceiling = ZIPArchive.predictedSize(files: initial.packages[0].files)
        let exact = try Preflight.analyze(f.config(mode: .maximumBytes(ceiling)))
        XCTAssertTrue(exact.canCreate)
        XCTAssertEqual(exact.archives.count, 2)
        XCTAssertTrue(exact.archives.allSatisfy { $0.predictedBytes <= ceiling && !$0.oversized })
        let tooSmall = try Preflight.analyze(f.config(mode: .maximumBytes(ceiling - 1)))
        XCTAssertFalse(tooSmall.canCreate)
        XCTAssertTrue(tooSmall.archives.allSatisfy(\.oversized))
        XCTAssertTrue(tooSmall.warnings.contains { $0.contains("Explicit acknowledgment") })
        let acknowledged = try Preflight.analyze(f.config(mode: .maximumBytes(ceiling - 1), acknowledged: true))
        XCTAssertTrue(acknowledged.canCreate)
        XCTAssertTrue(acknowledged.archives.allSatisfy { $0.packages.count == 1 })
    }

    func testCountModeProducesExactlyNBalancedIndivisibleArchives() throws {
        let f = try Fixture()
        for (i, size) in [9000, 8000, 7000, 6000, 5000, 4000, 3000].enumerated() { try f.clip("C\(i)", size: size) }
        let report = try Preflight.analyze(f.config(mode: .archiveCount(3)))
        XCTAssertTrue(report.canCreate)
        XCTAssertEqual(report.archives.count, 3)
        XCTAssertTrue(report.archives.allSatisfy { !$0.packages.isEmpty && $0.files.count == $0.packages.count * 2 })
        XCTAssertEqual(Set(report.archives.flatMap(\.files).map(\.relativePath)), Set(report.files.map(\.relativePath)))
        XCTAssertEqual(report.archives.flatMap(\.files).count, report.files.count)
        let sizes = report.archives.map(\.predictedBytes)
        XCTAssertLessThan(sizes.max()! - sizes.min()!, 5000)
        XCTAssertFalse(try Preflight.analyze(f.config(mode: .archiveCount(8))).canCreate)
        XCTAssertFalse(try Preflight.analyze(f.config(mode: .archiveCount(0))).canCreate)
    }

    func testStreamingHashIsBoundedAndDetectsMutationDuringRead() throws {
        let f = try Fixture(); try f.clip(size: 9_000_000)
        let source = try ReadOnlySource(url: f.source)
        let media = try source.scan().first { $0.kind == .media }!
        var seen: UInt64 = 0
        let digest = try source.hash(media, cancellation: CancellationToken()) { chunk in XCTAssertLessThanOrEqual(chunk, 4 * 1024 * 1024); seen += chunk }
        XCTAssertEqual(seen, media.size)
        XCTAssertEqual(digest, SHA256.hash(data: try Data(contentsOf: f.source.appendingPathComponent(media.relativePath))).map { String(format: "%02x", $0) }.joined())
        var mutated = false
        XCTAssertThrowsError(try source.stream(media, cancellation: CancellationToken()) { _ in
            if !mutated {
                mutated = true
                let handle = try FileHandle(forWritingTo: f.source.appendingPathComponent(media.relativePath))
                try handle.write(contentsOf: Data([0xFF])); try handle.close()
            }
        })
    }

    func testSourceReplacementDeletionAndTreeChangesDetected() throws {
        for mutation in ["replace", "delete", "add", "symlink"] {
            let f = try Fixture(); try f.clip()
            let source = try ReadOnlySource(url: f.source)
            let files = try source.scan()
            let media = files.first { $0.kind == .media }!
            let url = f.source.appendingPathComponent(media.relativePath)
            if mutation == "add" { try Data([1]).write(to: f.source.appendingPathComponent("NEW.xml")) }
            else {
                try FileManager.default.removeItem(at: url)
                if mutation == "replace" { try Data(repeating: 0, count: Int(media.size)).write(to: url) }
                if mutation == "symlink" { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.source.appendingPathComponent("A001.xml")) }
            }
            XCTAssertThrowsError(try source.validateSnapshot(files), mutation)
            XCTAssertThrowsError(try source.stream(media, cancellation: CancellationToken()) { _ in }, mutation)
        }
    }

    func testDestinationRejectsSourceHardlinksSymlinksTraversalAndOverwrite() throws {
        let f = try Fixture(); try f.clip()
        let before = try f.snapshot(f.source)
        let destination = try Destination(url: f.destination, source: ReadOnlySource(url: f.source))
        let original = f.source.appendingPathComponent("A001.mov")
        try FileManager.default.createSymbolicLink(at: f.destination.appendingPathComponent("linked"), withDestinationURL: original)
        XCTAssertThrowsError(try destination.openRead("linked"))
        XCTAssertThrowsError(try destination.createExclusive("linked"))
        XCTAssertThrowsError(try destination.createExclusive("../source/NEW.mov"))
        try FileManager.default.linkItem(at: original, to: f.destination.appendingPathComponent("hardlink"))
        XCTAssertThrowsError(try destination.writeAtomic(Data([0]), name: "hardlink", replace: true))
        XCTAssertThrowsError(try destination.openRead("hardlink"))
        try destination.writeAtomic(Data([1]), name: "keep", replace: false)
        try destination.writeAtomic(Data([2]), name: "candidate", replace: false)
        XCTAssertThrowsError(try destination.renameExclusive(from: "candidate", to: "keep"))
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("keep")), Data([1]))
        XCTAssertEqual(try f.snapshot(f.source), before)
    }

    func testDirectoryReplacementAndCancellationAreSafe() throws {
        let f = try Fixture(); try f.clip()
        let destination = try Destination(url: f.destination)
        try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("old-destination"))
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try destination.createExclusive("unsafe"))
        XCTAssertEqual(try f.snapshot(f.destination), [:])
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try Preflight.analyze(f.config(), cancellation: cancellation)) { XCTAssertEqual($0 as? HandoffError, .cancelled) }
        XCTAssertEqual(try f.snapshot(f.destination), [:])
    }

    func testPromotionRequiresTheExactPreviouslyVerifiedObject() throws {
        let f = try Fixture(); try f.clip()
        let destination = try Destination(url: f.destination)
        try destination.writeAtomic(Data([1, 2, 3]), name: ".A.zip.partial", replace: false)
        let descriptor = try destination.openRead(".A.zip.partial")
        let expected = fileIdentity(try descriptorStatus(descriptor, context: "test partial"))
        Darwin.close(descriptor)
        try destination.writeAtomic(Data([1, 2, 3]), name: ".A.zip.partial", replace: true)
        XCTAssertThrowsError(try destination.renameExclusive(from: ".A.zip.partial", to: "A.zip", expectedIdentity: expected))
        XCTAssertFalse(try destination.names().contains("A.zip"))
        let replacement = try destination.openRead(".A.zip.partial")
        let actual = fileIdentity(try descriptorStatus(replacement, context: "replacement"))
        Darwin.close(replacement)
        try destination.renameExclusive(from: ".A.zip.partial", to: "A.zip", expectedIdentity: actual)
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("A.zip")), Data([1, 2, 3]))
    }

    func testDestinationIdentityRecordsPromotionAndRejectsUnsafeNames() throws {
        let f = try Fixture()
        let destination = try Destination(url: f.destination)
        try destination.writeAtomic(Data([1, 2, 3]), name: ".A.zip.partial", replace: false)
        let partial = try destination.identityOf(".A.zip.partial")
        try destination.renameExclusive(from: ".A.zip.partial", to: "A.zip", expectedIdentity: partial)
        let promoted = try destination.identityOf("A.zip")
        XCTAssertTrue(sameObject(partial, promoted))
        XCTAssertEqual(promoted.size, partial.size)
        XCTAssertEqual(promoted, try destination.identityOf("A.zip"))
        try destination.writeAtomic(Data([1, 2, 3]), name: "A.zip", replace: true)
        XCTAssertNotEqual(promoted, try destination.identityOf("A.zip"))
        XCTAssertThrowsError(try destination.identityOf(".A.zip.partial"))
        XCTAssertThrowsError(try destination.identityOf("../source"))
        try FileManager.default.createSymbolicLink(at: f.destination.appendingPathComponent("linked.zip"), withDestinationURL: f.destination.appendingPathComponent("A.zip"))
        XCTAssertThrowsError(try destination.identityOf("linked.zip"))
        try FileManager.default.createDirectory(at: f.destination.appendingPathComponent("directory.zip"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try destination.identityOf("directory.zip"))
    }

    func testFilesystemLimitsAndUnsafePrefix() throws {
        XCTAssertEqual(Destination.maximumFileBytes(filesystem: "msdos"), UInt64(UInt32.max))
        XCTAssertEqual(Destination.maximumFileBytes(filesystem: "FAT32"), UInt64(UInt32.max))
        XCTAssertNil(Destination.maximumFileBytes(filesystem: "apfs"))
        XCTAssertNil(Destination.maximumFileBytes(filesystem: "exfat"))
        let f = try Fixture(); try f.clip()
        var config = f.config(); config.prefix = "../../escape"
        XCTAssertFalse(try Preflight.analyze(config).canCreate)
        config.prefix = "GOOD\nNAME"
        XCTAssertFalse(try Preflight.analyze(config).canCreate)
        XCTAssertEqual(try f.snapshot(f.destination), [:])
    }

    func testColonFilenamesBlockDuringPreflightBeforeAnyWrite() throws {
        let f = try Fixture(); try f.clip("A:001")
        let before = try f.snapshot(f.source)
        let report = try Preflight.analyze(f.config())
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.issues.contains { $0.contains("Unsafe or unsupported filename") && $0.contains("A:001") })
        XCTAssertEqual(try f.snapshot(f.source), before)
        XCTAssertEqual(try f.snapshot(f.destination), [:])
    }
}
