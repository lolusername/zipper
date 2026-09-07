import XCTest
import Foundation
@testable import HandoffCore

final class ReportCapacityTests: XCTestCase {
    func testLargeValidInventoryIsBlockedBeforeWritingUnreadableManifest() throws {
        let fixture = try JobIntegrationTests.Fixture(clips: 1, bytes: 1)
        defer { fixture.clean() }
        var preflight = try fixture.plan(count: 1)
        let template = preflight.packages[0]
        let packages = (0..<9_000).map { index -> ClipPackage in
            let name = String(repeating: "C", count: 180) + String(format: "%05d", index)
            var media = template.media, xml = template.xml
            media.relativePath = name + ".mov"; media.basename = name
            xml.relativePath = name + ".xml"; xml.basename = name
            media.sha256 = String(repeating: "a", count: 64); xml.sha256 = String(repeating: "b", count: 64)
            return ClipPackage(basename: name, media: media, xml: xml)
        }
        preflight.packages = packages
        preflight.files = packages.flatMap(\.files)
        preflight.archives = [ArchivePlan(name: "FOOTAGE_001.zip", packages: packages, predictedBytes: ZIPArchive.predictedSize(files: preflight.files))]
        let job = JobRecord(preflight: preflight)
        try JobEngine.validateRecord(job, requireComplete: false)
        // This is valid metadata for a physically possible card, with thousands of
        // small clips. No large media transfer is needed to exercise the report limit.
        XCTAssertNotNil(try Preflight.reportCapacityIssue(preflight))
        XCTAssertThrowsError(try JobEngine.encodedReport(job))
        XCTAssertEqual(try fixture.names(), [], "Preflight and the writer's size guard must reject before destination writes.")
        let encoded = try JobEngine.encoder().encode(job)
        XCTAssertGreaterThan(encoded.count, JobEngine.maximumReportBytes)
        // Deliberately bypass the production write guard to check that the reader
        // enforces the exact same bound for externally supplied state files.
        try encoded.write(to: fixture.destination.appendingPathComponent(JobEngine.stateName))
        XCTAssertThrowsError(try JobEngine.loadState(destinationURL: fixture.destination))
    }

    func testNormalInventoryFitsAndWrittenStateIsReadable() throws {
        let fixture = try JobIntegrationTests.Fixture(clips: 3, bytes: 1)
        defer { fixture.clean() }
        let preflight = try fixture.plan(count: 2)
        XCTAssertNil(try Preflight.reportCapacityIssue(preflight))
        let job = JobRecord(preflight: preflight)
        let encoded = try JobEngine.encodedReport(job)
        XCTAssertLessThanOrEqual(encoded.count, JobEngine.maximumReportBytes)
        try encoded.write(to: fixture.destination.appendingPathComponent(JobEngine.stateName))
        XCTAssertEqual(try JobEngine.loadState(destinationURL: fixture.destination).id, job.id)
    }
}
