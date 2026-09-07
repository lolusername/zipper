import XCTest
import Foundation
import CryptoKit
@testable import HandoffCore

/// Disposable adversarial deliveries: no test reads or writes real camera media.
final class ArchiveIntegrityAuditTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-integrity-audit-\(UUID().uuidString)")
        var source: URL { root.appendingPathComponent("source") }
        var destination: URL { root.appendingPathComponent("destination") }
        let job: JobRecord

        init(basename: String = "DISCLOSURE_DAY0115", triplet: Bool = true) throws {
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var inputs = [
                (basename + ".MXF", Data((0..<127).map { UInt8($0) })),
                (basename + (triplet ? "M01" : "") + ".XML", Data("<clip/>".utf8))
            ]
            if triplet { inputs.append((basename + "R01.BIM", Data([0x42, 0x49, 0x4d, 0, 1, 2]))) }
            for (name, data) in inputs { try data.write(to: source.appendingPathComponent(name)) }
            let config = JobConfiguration(sourcePath: source.path, destinationPath: destination.path, mode: .archiveCount(1))
            job = try JobEngine().create(preflight: Preflight.analyze(config))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func verifyZIP() throws {
            let archive = job.archives[0]
            try ZIPArchive.verify(name: archive.plan.name, files: archive.plan.files,
                                  destination: Destination(url: destination), cancellation: CancellationToken()) { _, _ in }
        }

        func writeManifest(_ record: JobRecord) throws {
            try JobEngine.encoder().encode(record).write(to: destination.appendingPathComponent(JobEngine.manifestName))
        }
    }

    func testCorruptRequiredHumanReportsCannotReceivePassingDeliveryCheck() throws {
        let fixture = try Fixture()
        for name in ["HANDOFF_MANIFEST.txt", "HANDOFF_LOG.txt"] {
            let path = fixture.destination.appendingPathComponent(name)
            let original = try Data(contentsOf: path)
            try Data("Unrelated delivery. Wrong files, wrong checksums, wrong job.\n".utf8).write(to: path)
            for deep in [false, true] {
                let report = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: deep)
                XCTAssertFalse(report.passed, "A corrupt required \(name) received PASS (deep: \(deep)).")
                XCTAssertTrue(report.issues.contains { $0.contains(name) }, "The affected report should be identified.")
            }
            try original.write(to: path)
        }
    }

    func testLegacy100And101ReportFormatsStillVerifyWithoutOriginalSource() throws {
        for version in ["1.0.0", "1.0.1"] {
            let fixture = try Fixture(basename: "LEGACY", triplet: false)
            var legacy = fixture.job
            legacy.applicationVersion = version
            let human = JobEngine.humanReport(legacy)
            XCTAssertTrue(human.contains("Verification: PASS — final source SHA-256 and every archived member match\n"))
            XCTAssertFalse(human.contains("Delivery completion: this text is not a completion marker."))
            XCTAssertEqual(human.contains("\nBIM: 0\n"), version != "1.0.0")
            try Data(human.utf8).write(to: fixture.destination.appendingPathComponent("HANDOFF_MANIFEST.txt"))
            func oldShape(_ value: Any) -> Any {
                if let dictionary = value as? [String: Any] {
                    return dictionary.filter { $0.key != "auxiliaryFiles" && $0.key != "bimCount" }.mapValues(oldShape)
                }
                if let array = value as? [Any] { return array.map(oldShape) }
                return value
            }
            let encoded = try JobEngine.encoder().encode(legacy)
            let historical = try JSONSerialization.data(withJSONObject: oldShape(JSONSerialization.jsonObject(with: encoded)))
            try historical.write(to: fixture.destination.appendingPathComponent(JobEngine.manifestName))
            try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("card-removed"))
            for deep in [false, true] {
                let result = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: deep)
                XCTAssertTrue(result.passed, result.issues.joined(separator: "\n"))
                XCTAssertEqual(result.sourcePath, legacy.preflight.configuration.sourcePath)
                XCTAssertEqual(result.destination?.canonicalPath, try Destination(url: fixture.destination).info.canonicalPath)
            }
        }
    }

    func testCanonicalUnicodeEqualityCannotHideDifferentManifestMemberBytes() throws {
        let first = "A\u{0327}\u{0301}"
        let second = "A\u{0301}\u{0327}"
        XCTAssertEqual(first, second, "Swift String compares canonically equivalent Unicode as equal.")
        XCTAssertNotEqual(Array(first.utf8), Array(second.utf8))
        let fixture = try Fixture(basename: first)
        var tampered = fixture.job
        let original = tampered.archives[0].plan.packages[0]
        let replacement = Array(original.basename.utf8) == Array(first.utf8) ? second : first
        XCTAssertEqual(original.basename, replacement)
        XCTAssertNotEqual(Array(original.basename.utf8), Array(replacement.utf8))
        XCTAssertEqual(original.basename.utf8.count, replacement.utf8.count)

        func renamed(_ file: SourceFile, suffix: String) -> SourceFile {
            var file = file
            file.basename = replacement + suffix
            file.relativePath = file.basename + "." + (file.relativePath as NSString).pathExtension
            return file
        }
        let changed = ClipPackage(basename: replacement,
                                  media: renamed(original.media, suffix: ""),
                                  xml: renamed(original.xml, suffix: "M01"),
                                  auxiliaryFiles: original.auxiliaryFiles.map { renamed($0, suffix: "R01") })
        tampered.archives[0].plan.packages = [changed]
        tampered.preflight.archives = tampered.archives.map(\.plan)
        tampered.preflight.packages = [changed]
        // Source inventory still carries the actual original filename bytes.
        XCTAssertNotEqual(changed, original, "Evidence model equality must retain filename-byte distinctions.")
        XCTAssertThrowsError(try JobEngine.validateRecord(tampered, requireComplete: true),
                             "Source inventory and archive membership contain different UTF-8 names.")
        try fixture.writeManifest(tampered)
        do {
            let shallow = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: false)
            XCTAssertFalse(shallow.passed, "A contradictory manifest must be rejected even by an archive-hash-only check.")
        } catch { /* Rejecting an invalid manifest before archive IO is correct. */ }
        do {
            let deep = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: true)
            XCTAssertFalse(deep.passed, "Deep verification must compare ZIP header filename bytes.")
        } catch { /* Rejecting an invalid manifest before archive IO is correct. */ }
    }

    func testCanonicalUnicodeSourceInventoryRenameCannotPassDeepVerification() throws {
        let first = "A\u{0327}\u{0301}"
        let second = "A\u{0301}\u{0327}"
        let fixture = try Fixture(basename: first)
        var tampered = fixture.job
        let original = tampered.preflight.packages[0].basename
        let replacement = Array(original.utf8) == Array(first.utf8) ? second : first
        tampered.preflight.files = tampered.preflight.files.map { file in
            var file = file
            let suffix = file.kind == .xml ? "M01" : file.kind == .bim ? "R01" : ""
            file.basename = replacement + suffix
            file.relativePath = file.basename + "." + (file.relativePath as NSString).pathExtension
            return file
        }
        XCTAssertThrowsError(try JobEngine.validateRecord(tampered, requireComplete: true))
        try fixture.writeManifest(tampered)
        for deep in [false, true] {
            do {
                let report = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: deep)
                XCTAssertFalse(report.passed, "Contradictory source filename bytes must fail (deep: \(deep)).")
            } catch { /* Rejecting invalid JSON evidence before IO is correct. */ }
        }
    }

    func testCanonicalUnicodeArchiveNameDoesNotSatisfyDifferentExpectedFilenameBytes() throws {
        let fixture = try Fixture()
        let actualName = "A\u{0327}\u{0301}.zip"
        let expectedName = "A\u{0301}\u{0327}.zip"
        var tampered = fixture.job
        try FileManager.default.moveItem(at: fixture.destination.appendingPathComponent(tampered.archives[0].plan.name),
                                         to: fixture.destination.appendingPathComponent(actualName))
        let enumerated = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).first { $0.hasSuffix(".zip") })
        // APFS preserves spelling while lookup treats these names as equivalent.
        let alternate = Array(enumerated.utf8) == Array(actualName.utf8) ? expectedName : actualName
        XCTAssertNotEqual(Array(enumerated.utf8), Array(alternate.utf8))
        tampered.archives[0].plan.name = alternate
        tampered.preflight.archives = tampered.archives.map(\.plan)
        try fixture.writeManifest(tampered)
        try Data(JobEngine.humanReport(tampered).utf8).write(to: fixture.destination.appendingPathComponent("HANDOFF_MANIFEST.txt"))
        let sums = "\(tampered.archives[0].sha256!)  \(alternate)\n"
        try Data(sums.utf8).write(to: fixture.destination.appendingPathComponent("SHA256SUMS.txt"))
        for deep in [false, true] {
            let result = try HandoffVerifier.verify(destinationURL: fixture.destination, deep: deep)
            XCTAssertFalse(result.passed, "The physical archive name differs from the manifest's exact UTF-8 spelling.")
        }
    }

    func testEveryZIP64StructuralFieldAndMemberBoundaryRejectsSingleByteDamage() throws {
        let fixture = try Fixture()
        let plan = fixture.job.archives[0].plan
        let path = fixture.destination.appendingPathComponent(plan.name)
        let original = try Data(contentsOf: path)
        var ranges: [(String, Range<Int>)] = []
        var offset = 0
        for file in plan.files {
            let headerLength = 50 + file.relativePath.utf8.count
            ranges.append(("local header for \(file.relativePath)", offset..<(offset + headerLength)))
            offset += headerLength + Int(file.size)
            ranges.append(("data descriptor for \(file.relativePath)", offset..<(offset + 24)))
            offset += 24
        }
        for file in plan.files {
            let headerLength = 74 + file.relativePath.utf8.count
            ranges.append(("central directory for \(file.relativePath)", offset..<(offset + headerLength)))
            offset += headerLength
        }
        ranges.append(("ZIP64 end records", offset..<original.count))
        XCTAssertEqual(original.count - offset, 98)
        for (label, range) in ranges {
            for byte in range {
                var damaged = original
                damaged[byte] ^= 1
                try damaged.write(to: path)
                XCTAssertThrowsError(try fixture.verifyZIP(), "Accepted damaged \(label), byte \(byte).")
            }
        }
        try original.write(to: path)
        XCTAssertNoThrow(try fixture.verifyZIP())
    }

    func testArchiveMemberOrderAndInventoriesCannotOmitOrDuplicateBIM() throws {
        let fixture = try Fixture()
        let original = fixture.job
        var omitted = original
        omitted.archives[0].plan.packages[0].auxiliaryFiles = []
        omitted.preflight.archives = omitted.archives.map(\.plan)
        omitted.preflight.packages = omitted.archives.flatMap { $0.plan.packages }
        XCTAssertThrowsError(try JobEngine.validateRecord(omitted, requireComplete: true))

        var duplicated = original
        duplicated.archives[0].plan.packages[0].auxiliaryFiles += duplicated.archives[0].plan.packages[0].auxiliaryFiles
        duplicated.preflight.archives = duplicated.archives.map(\.plan)
        duplicated.preflight.packages = duplicated.archives.flatMap { $0.plan.packages }
        XCTAssertThrowsError(try JobEngine.validateRecord(duplicated, requireComplete: true))

        let archive = original.archives[0]
        let destination = try Destination(url: fixture.destination)
        XCTAssertThrowsError(try ZIPArchive.verify(name: archive.plan.name, files: Array(archive.plan.files.reversed()),
                                                   destination: destination, cancellation: CancellationToken()) { _, _ in })
    }
}
