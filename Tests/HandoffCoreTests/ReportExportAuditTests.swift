import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

final class ReportExportAuditTests: XCTestCase {
    private let body = Data("Fixture verification report\n".utf8)

    private func completedFixture() throws -> (JobIntegrationTests.Fixture, VerificationReport) {
        let fixture = try JobIntegrationTests.Fixture(clips: 1)
        do {
            _ = try JobEngine().create(preflight: fixture.plan(count: 1))
            return (fixture, try HandoffVerifier.verify(destinationURL: fixture.destination))
        } catch { fixture.clean(); throw error }
    }

    private func snapshot(_ url: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map {
            ($0.lastPathComponent, Data(SHA256.hash(data: try Data(contentsOf: $0))))
        })
    }

    func testStandaloneVerificationExportProtectsManifestSourceWithoutSidebarSelection() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.sourcePath, f.source.path)
        let before = try snapshot(f.source)
        XCTAssertThrowsError(try ReportExporter.write(body, to: f.source.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [try XCTUnwrap(report.sourcePath)],
                                                    expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try snapshot(f.source), before)
        let nested = f.source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ReportExporter.write(body, to: nested.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [f.source.path], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: nested.path), [])
    }

    func testExportProtectsBothCurrentSelectionAndVerifiedOriginalAndAliases() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        let otherSource = f.root.appendingPathComponent("AnotherCamera")
        try FileManager.default.createDirectory(at: otherSource, withIntermediateDirectories: false)
        let alias = f.root.appendingPathComponent("SourceLink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        for target in [f.source, otherSource, alias, f.root] {
            XCTAssertThrowsError(try ReportExporter.write(body, to: target.appendingPathComponent("Report.txt"),
                                                        protectedSourcePaths: [otherSource.path, f.source.path],
                                                        expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Report.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".Report.txt.pending").path))
        }
    }

    func testMissingOriginalBlocksExportWhileDeliveryVerificationStillWorks() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("DisconnectedSource"))
        let elsewhere = f.root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ReportExporter.write(body, to: elsewhere.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [f.source.path], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        let output = f.destination.appendingPathComponent("Report.txt")
        XCTAssertTrue(try HandoffVerifier.verify(destinationURL: f.destination).passed)
        XCTAssertThrowsError(try ReportExporter.write(body, to: output, protectedSourcePaths: [f.source.path], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMissingOriginalRejectsReplacedDeliveryDirectory() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("DisconnectedSource"))
        try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("OriginalDelivery"))
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ReportExporter.write(body, to: f.destination.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [f.source.path], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try f.names(), [])
    }

    func testReplacedSourcePathCannotPermitExportInsideRenamedOriginals() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        let moved = f.root.appendingPathComponent("RenamedOriginals")
        try FileManager.default.moveItem(at: f.source, to: moved)
        try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: false)
        let before = try snapshot(moved)
        XCTAssertThrowsError(try ReportExporter.write(body, to: moved.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [f.source.path],
                                                    expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try snapshot(moved), before)
    }

    func testExportToSeparateFolderPreservesSourceAndNeverReplacesExistingFile() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        let before = try snapshot(f.source)
        let output = f.destination.appendingPathComponent("Report.txt")
        try ReportExporter.write(body, to: output, protectedSourcePaths: [f.source.path], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)])
        XCTAssertThrowsError(try ReportExporter.write(Data("Replacement".utf8), to: output,
                                                    protectedSourcePaths: [f.source.path], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try Data(contentsOf: output), body)
        XCTAssertEqual(try snapshot(f.source), before)
    }

    func testUnknownSourceContextCannotEnableUnprotectedExport() throws {
        let (f, report) = try completedFixture(); defer { f.clean() }
        let before = try snapshot(f.source)
        XCTAssertThrowsError(try ReportExporter.write(body, to: f.source.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [], expectedSourceIdentities: [f.source.path: try XCTUnwrap(report.sourceIdentity)]))
        XCTAssertEqual(try snapshot(f.source), before)
    }

    func testUnreadableButTraversableSourceCannotUseDeliveryFallbackToWriteInsideIt() throws {
        let f = try JobIntegrationTests.Fixture(clips: 1); defer { f.clean() }
        let nested = f.source.appendingPathComponent("CopiedDelivery")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(f.source.path, 0o311), 0)
        defer { chmod(f.source.path, 0o700) }
        XCTAssertThrowsError(try ReadOnlySource(url: f.source))
        XCTAssertThrowsError(try ReportExporter.write(body, to: nested.appendingPathComponent("Report.txt"),
                                                    protectedSourcePaths: [f.source.path]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: nested.path), [])
    }
}
