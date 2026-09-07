import XCTest
import Foundation
import CryptoKit
@testable import HandoffCore

/// Camera card regressions use the exact MXF/M01.XML/R01.BIM names shown by the user.
final class CameraTripletTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Zipper-CameraTriplets-\(UUID().uuidString)")
        var source: URL { root.appendingPathComponent("Originals") }
        var destination: URL { root.appendingPathComponent("Delivery") }

        init(clips: Int = 3) throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for index in 0..<clips {
                try triplet(String(format: "DISCLOSURE_DAY%04d", 115 + index), seed: index + 1)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, _ data: Data) throws {
            try data.write(to: source.appendingPathComponent(name))
        }

        func triplet(_ name: String, seed: Int = 1, includeBIM: Bool = true) throws {
            try write(name + ".MXF", Data((0..<(4096 + seed)).map { UInt8(truncatingIfNeeded: $0 + seed) }))
            try write(name + "M01.XML", Data("<NonRealTimeMeta clip=\"\(name)\"/>".utf8))
            if includeBIM { try write(name + "R01.BIM", Data("BIM payload for \(name): \(String(repeating: "\(seed)bd", count: 181))".utf8)) }
        }

        func plan(_ mode: BatchingMode = .archiveCount(2), acknowledged: Bool = false) throws -> PreflightReport {
            try Preflight.analyze(JobConfiguration(sourcePath: source.path, destinationPath: destination.path,
                                                   mode: mode, acknowledgedOversized: acknowledged))
        }

        func destinationNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        }

        func snapshot() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: source.path).map {
                ($0, try Data(contentsOf: source.appendingPathComponent($0)))
            })
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertCompletePackages(_ report: PreflightReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(report.canCreate, report.issues.joined(separator: "\n"), file: file, line: line)
        XCTAssertEqual(report.packages.count, 3, file: file, line: line)
        XCTAssertEqual(report.archives.flatMap(\.files).count, 9, file: file, line: line)
        XCTAssertEqual(Set(report.archives.flatMap(\.files).map(\.relativePath)), Set(report.files.map(\.relativePath)), file: file, line: line)
        for package in report.packages {
            let expected = Set([package.basename + ".MXF", package.basename + "M01.XML", package.basename + "R01.BIM"])
            XCTAssertEqual(Set(package.files.map(\.relativePath)), expected, file: file, line: line)
            XCTAssertEqual(package.auxiliaryFiles.map(\.kind), [.bim], file: file, line: line)
            XCTAssertEqual(package.totalSize, package.files.reduce(0) { $0 + $1.size }, file: file, line: line)
            let containing = report.archives.filter { !Set($0.files.map(\.relativePath)).isDisjoint(with: expected) }
            XCTAssertEqual(containing.count, 1, "A clip's three files must share one independent archive", file: file, line: line)
            XCTAssertTrue(expected.isSubset(of: Set(containing.flatMap(\.files).map(\.relativePath))), file: file, line: line)
        }
    }

    func testScreenshotTripletPreflightIncludesAllNineFilesAndWritesNothing() throws {
        let f = try Fixture()
        let before = try f.snapshot()
        let identity = try ReadOnlySource(url: f.source).identity
        let report = try f.plan()
        assertCompletePackages(report)
        XCTAssertEqual(report.files.filter { $0.kind == .media }.count, 3)
        XCTAssertEqual(report.files.filter { $0.kind == .xml }.count, 3)
        XCTAssertEqual(report.files.filter { $0.kind == .bim }.count, 3)
        XCTAssertEqual(report.totalBytes, before.values.reduce(0) { $0 + UInt64($1.count) })
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertEqual(try ReadOnlySource(url: f.source).identity, identity)
        XCTAssertEqual(try f.destinationNames(), [])
    }

    func testArchiveCountOneTwoAndThreeKeepsEachTripletIndivisible() throws {
        let f = try Fixture()
        for count in 1...3 {
            let plan = try f.plan(.archiveCount(count))
            assertCompletePackages(plan)
            XCTAssertEqual(plan.archives.count, count)
            XCTAssertTrue(plan.archives.allSatisfy { !$0.packages.isEmpty && $0.predictedBytes == ZIPArchive.predictedSize(files: $0.files) })
        }
        XCTAssertEqual(try f.destinationNames(), [])
    }

    func testMaximumSizeIncludesBIMPayloadAndZIPOverheadWithoutSplittingTriplets() throws {
        let f = try Fixture()
        let inventory = try f.plan(.archiveCount(1))
        let ceiling = try XCTUnwrap(inventory.packages.map { ZIPArchive.predictedSize(files: $0.files) }.max())
        let plan = try f.plan(.maximumBytes(ceiling))
        assertCompletePackages(plan)
        XCTAssertEqual(plan.archives.count, 3)
        XCTAssertTrue(plan.archives.allSatisfy { $0.predictedBytes <= ceiling && !$0.oversized })

        // Even when the media/XML pair fits, BIM and its ZIP entry make the clip oversized.
        let pairOnlyCeiling = try XCTUnwrap(inventory.packages.map { ZIPArchive.predictedSize(files: [$0.media, $0.xml]) }.max())
        let blocked = try f.plan(.maximumBytes(pairOnlyCeiling))
        XCTAssertFalse(blocked.canCreate)
        XCTAssertEqual(blocked.archives.count, 3)
        XCTAssertTrue(blocked.archives.allSatisfy { $0.oversized && $0.packages.count == 1 && $0.files.count == 3 })
        XCTAssertThrowsError(try JobEngine().create(preflight: blocked))
        XCTAssertEqual(try f.destinationNames(), [])
        let approved = try f.plan(.maximumBytes(pairOnlyCeiling), acknowledged: true)
        assertCompletePackages(approved)
        let completed = try JobEngine().create(preflight: approved)
        XCTAssertTrue(completed.archives.allSatisfy { $0.actualBytes == $0.plan.predictedBytes && $0.plan.files.count == 3 })
    }

    func testCompletedHandoffPreservesAllNamesBytesAndHashesAndVerifiesWithoutOriginals() throws {
        let f = try Fixture()
        let before = try f.snapshot()
        let plan = try f.plan()
        let job = try JobEngine().create(preflight: plan)
        XCTAssertEqual(job.status, .completed)
        XCTAssertTrue(job.finalSourceVerified)
        XCTAssertEqual(job.deliveryStatistics?.sourceFileCount, 9)
        XCTAssertEqual(job.deliveryStatistics?.bimCount, 3)
        XCTAssertEqual(job.deliveryStatistics?.unexpectedFileCount, 0)
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertEqual(Set(job.archives.flatMap { $0.plan.files }.map(\.relativePath)), Set(before.keys))
        for archive in job.archives {
            XCTAssertEqual(archive.actualBytes, archive.plan.predictedBytes)
            for member in archive.plan.files {
                let original = try XCTUnwrap(before[member.relativePath])
                XCTAssertEqual(member.sha256, digest(original), member.relativePath)
                // Apple's independent unzip must also extract every unchanged sidecar.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-p", f.destination.appendingPathComponent(archive.plan.name).path, member.relativePath]
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let extracted = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                XCTAssertEqual(extracted, original, member.relativePath)
            }
        }
        let reportText = try String(contentsOf: f.destination.appendingPathComponent("HANDOFF_MANIFEST.txt"), encoding: .utf8)
        for name in before.keys { XCTAssertTrue(reportText.contains(name), name) }
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("Card removed"))
        let deep = try HandoffVerifier.verify(destinationURL: f.destination, deep: true)
        XCTAssertTrue(deep.passed, deep.issues.joined(separator: "\n"))
        XCTAssertEqual(deep.checkedFiles, 9)
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination, deep: false).passed)
    }

    func testCorruptBIMPayloadFailsIndependentMemberAndWholeHandoffVerification() throws {
        let f = try Fixture()
        let job = try JobEngine().create(preflight: f.plan())
        let archive = try XCTUnwrap(job.archives.first)
        let bim = try XCTUnwrap(archive.plan.files.first { $0.kind == .bim })
        let payload = try Data(contentsOf: f.source.appendingPathComponent(bim.relativePath))
        let archiveURL = f.destination.appendingPathComponent(archive.plan.name)
        var bytes = try Data(contentsOf: archiveURL)
        let offset = try XCTUnwrap(bytes.range(of: payload)).lowerBound
        bytes[offset] ^= 0xff
        try bytes.write(to: archiveURL)
        let destination = try Destination(url: f.destination)
        XCTAssertThrowsError(try ZIPArchive.verify(name: archive.plan.name, files: archive.plan.files,
                                                   destination: destination, cancellation: CancellationToken()) { _, _ in })
        XCTAssertFalse(try HandoffVerifier.verify(destinationURL: f.destination, deep: true).passed)
        XCTAssertThrowsError(try JobEngine().resume(destinationURL: f.destination))
        XCTAssertEqual(try Data(contentsOf: archiveURL), bytes, "A corrupt existing archive must be retained for review")
    }

    func testCancellationAndResumeRetainsVerifiedTripletArchiveAndRehashesAllBIMFiles() throws {
        let f = try Fixture()
        let before = try f.snapshot()
        let token = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(), cancellation: token) {
            if $0.verifiedArchives == 1 { token.cancel() }
        })
        let interrupted = try JobEngine.loadState(destinationURL: f.destination)
        XCTAssertEqual(interrupted.status, .interrupted)
        let first = try XCTUnwrap(interrupted.archives.first)
        XCTAssertTrue(first.plan.files.contains { $0.kind == .bim && $0.sha256 != nil })
        let kept = try Data(contentsOf: f.destination.appendingPathComponent(first.plan.name))
        var last = JobProgress()
        let recovered = try JobEngine().resume(destinationURL: f.destination) { last = $0 }
        XCTAssertEqual(recovered.status, .completed)
        XCTAssertTrue(recovered.events.contains { $0.message.contains("archive SHA-256 and every member reverified") })
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent(first.plan.name)), kept)
        XCTAssertEqual(last.verifiedBytes, recovered.preflight.totalBytes)
        let archiveBytes = recovered.archives.reduce(0) { $0 + ($1.actualBytes ?? 0) }
        XCTAssertEqual(last.bytesRead, recovered.preflight.totalBytes * 4 - first.plan.files.reduce(0) { $0 + $1.size } + archiveBytes,
                       "Resume hashes every original including BIM, reopens all members, and rehashes all originals at completion")
        for file in recovered.archives.flatMap({ $0.plan.files }) where file.kind == .bim {
            XCTAssertEqual(file.sha256, digest(try XCTUnwrap(before[file.relativePath])))
        }
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertEqual(try HandoffVerifier.verify(destinationURL: f.destination).checkedFiles, 9)
    }

    func testBIMMutationAfterPreflightBlocksWithoutDestinationWrites() throws {
        let f = try Fixture()
        let plan = try f.plan()
        try f.write("DISCLOSURE_DAY0115R01.BIM", Data("changed metadata".utf8))
        XCTAssertThrowsError(try JobEngine().create(preflight: plan))
        XCTAssertEqual(try f.destinationNames(), [])
    }

    func testBIMMutationDuringFinalSourceCheckPreventsSuccessfulPublication() throws {
        let f = try Fixture()
        var changed = false
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan()) { progress in
            if progress.operation.contains("Final source stability"), !changed {
                changed = true
                try! f.write("DISCLOSURE_DAY0115R01.BIM", Data("late BIM mutation".utf8))
            }
        })
        XCTAssertTrue(changed)
        XCTAssertFalse(try JobEngine.loadState(destinationURL: f.destination).finalSourceVerified)
        XCTAssertFalse(try f.destinationNames().contains(JobEngine.manifestName))
    }

    func testBIMMutationAfterCancellationBlocksResumeAndPreservesVerifiedArchive() throws {
        let f = try Fixture()
        let token = CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight: f.plan(), cancellation: token) {
            if $0.verifiedArchives == 1 { token.cancel() }
        })
        let first = try Data(contentsOf: f.destination.appendingPathComponent("FOOTAGE_001.zip"))
        try f.write("DISCLOSURE_DAY0115R01.BIM", Data("changed after cancellation".utf8))
        XCTAssertThrowsError(try JobEngine().resume(destinationURL: f.destination))
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("FOOTAGE_001.zip")), first)
        XCTAssertFalse(try f.destinationNames().contains(JobEngine.manifestName))
    }

    func testOrphanBIMIsVisibleAndBlocksPreflight() throws {
        let f = try Fixture()
        try f.write("NO_CLIPR01.BIM", Data([1, 2, 3]))
        let report = try f.plan()
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.files.contains { $0.relativePath == "NO_CLIPR01.BIM" })
        XCTAssertTrue(report.issues.contains { $0.contains("NO_CLIPR01") })
        XCTAssertEqual(try f.destinationNames(), [])
    }

    func testExactAndM01XMLTogetherAreAmbiguousAndBlock() throws {
        let f = try Fixture()
        try f.write("DISCLOSURE_DAY0115.XML", Data("<extra/>".utf8))
        let report = try f.plan()
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.issues.contains { $0.lowercased().contains("ambig") })
        XCTAssertFalse(report.packages.contains { $0.basename == "DISCLOSURE_DAY0115" })
        XCTAssertEqual(try f.destinationNames(), [])
    }

    func testSharedXMLBetweenRealM01MediaStemAndCameraStemBlocksBoth() throws {
        let f = try Fixture(clips: 0)
        try f.write("CLIP.MXF", Data([1]))
        try f.write("CLIPM01.MXF", Data([2]))
        try f.write("CLIPM01.XML", Data("<shared/>".utf8))
        let report = try f.plan(.archiveCount(1))
        XCTAssertFalse(report.canCreate)
        XCTAssertTrue(report.issues.contains { $0.lowercased().contains("ambig") })
        XCTAssertTrue(report.packages.isEmpty)
    }

    func testSimilarNumberedStemsDoNotCrossAssociateSidecars() throws {
        let f = try Fixture(clips: 0)
        try f.triplet("CLIP1", seed: 1)
        try f.triplet("CLIP10", seed: 10)
        let report = try f.plan(.archiveCount(2))
        XCTAssertTrue(report.canCreate, report.issues.joined(separator: "\n"))
        XCTAssertEqual(Set(report.packages.map(\.basename)), ["CLIP1", "CLIP10"])
        for package in report.packages {
            XCTAssertEqual(package.xml.relativePath, package.basename + "M01.XML")
            XCTAssertEqual(package.auxiliaryFiles.map(\.relativePath), [package.basename + "R01.BIM"])
        }
    }

    func testRealMediaStemEndingM01IsNeverTruncated() throws {
        let f = try Fixture(clips: 0)
        try f.triplet("ACTUALM01")
        let report = try f.plan(.archiveCount(1))
        XCTAssertTrue(report.canCreate, report.issues.joined(separator: "\n"))
        let package = try XCTUnwrap(report.packages.first)
        XCTAssertEqual(package.basename, "ACTUALM01")
        XCTAssertEqual(package.xml.relativePath, "ACTUALM01M01.XML")
        XCTAssertEqual(package.auxiliaryFiles.map(\.relativePath), ["ACTUALM01R01.BIM"])
    }

    func testM01XMLWithoutOptionalBIMStillCreatesAndVerifies() throws {
        let f = try Fixture(clips: 0)
        try f.triplet("NO_BIM", includeBIM: false)
        let plan = try f.plan(.archiveCount(1))
        XCTAssertTrue(plan.canCreate, plan.issues.joined(separator: "\n"))
        XCTAssertEqual(plan.packages.first?.auxiliaryFiles, [])
        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(try JobEngine().create(preflight: plan).status, .completed)
        XCTAssertEqual(try HandoffVerifier.verify(destinationURL: f.destination).checkedFiles, 2)
    }

    func testLegacyExactBasenamePairsAndVersionOneManifestStateStillVerify() throws {
        let f = try Fixture(clips: 0)
        for name in ["LEGACY", "LEGACYM01"] {
            try f.write(name + ".MOV", Data("legacy movie \(name)".utf8))
            try f.write(name + ".XML", Data("<legacy id=\"\(name)\"/>".utf8))
        }
        let plan = try f.plan(.archiveCount(1))
        XCTAssertTrue(plan.canCreate, plan.issues.joined(separator: "\n"))
        XCTAssertEqual(Set(plan.packages.map(\.basename)), ["LEGACY", "LEGACYM01"])
        XCTAssertTrue(plan.packages.allSatisfy { $0.auxiliaryFiles.isEmpty && $0.xml.basename == $0.media.basename })
        let completed = try JobEngine().create(preflight: plan)

        // Produce the actual old v1 serialized shape, where neither new key exists.
        func legacyShape(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { $0.key != "auxiliaryFiles" && $0.key != "bimCount" }
                    .mapValues(legacyShape)
            }
            if let array = value as? [Any] { return array.map(legacyShape) }
            return value
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JobEngine.encoder().encode(completed)) as? [String: Any])
        object["schemaVersion"] = 1
        let oldJSON = try JSONSerialization.data(withJSONObject: legacyShape(object), options: [.sortedKeys])
        let decoded = try JobEngine.decoder().decode(JobRecord.self, from: oldJSON)
        XCTAssertTrue(decoded.preflight.packages.allSatisfy { $0.auxiliaryFiles.isEmpty })
        XCTAssertEqual(decoded.deliveryStatistics?.bimCount, 0)
        try oldJSON.write(to: f.destination.appendingPathComponent(JobEngine.stateName))
        try oldJSON.write(to: f.destination.appendingPathComponent(JobEngine.manifestName))
        XCTAssertEqual(try JobEngine.loadState(destinationURL: f.destination).id, completed.id)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("Old card removed"))
        let verified = try HandoffVerifier.verify(destinationURL: f.destination)
        XCTAssertTrue(verified.passed, verified.issues.joined(separator: "\n"))
        XCTAssertEqual(verified.checkedFiles, 4)
    }
}
