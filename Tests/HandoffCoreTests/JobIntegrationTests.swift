import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import HandoffCore

final class JobIntegrationTests: XCTestCase {
    struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        init(clips: Int = 3, bytes: Int = 8192) throws {
            root=FileManager.default.temporaryDirectory.appendingPathComponent("Zipper-JobTests-\(UUID().uuidString)")
            source=root.appendingPathComponent("Originals")
            destination=root.appendingPathComponent("Delivery")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            for n in 1...clips {
                let base=String(format:"A001C%03d",n)
                try Data((0..<bytes+n).map { UInt8(truncatingIfNeeded:$0+n) }).write(to:source.appendingPathComponent(base+".mov"))
                try Data("<clip name=\"\(base)\"/>".utf8).write(to:source.appendingPathComponent(base+".xml"))
            }
        }
        func clean() { try? FileManager.default.removeItem(at:root) }
        func plan(count:Int=2) throws -> PreflightReport { try Preflight.analyze(JobConfiguration(sourcePath:source.path,destinationPath:destination.path,mode:.archiveCount(count))) }
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath:destination.path).sorted() }
    }
    struct Snapshot: Equatable {
        let path: String
        let size: UInt64
        let hash: String
    }
    func snapshot(_ root:URL) throws -> [Snapshot] {
        let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        var values:[Snapshot]=[]
        for case let url as URL in enumerator {
            let relative=String(url.path.dropFirst(root.path.count+1))
            if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                let data=try Data(contentsOf:url)
                values.append(Snapshot(path:relative,size:UInt64(data.count),hash:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()))
            }
        }
        return values.sorted{$0.path<$1.path}
    }
    func testFullHandoffPreservesRecursiveSourceByteForByteAndVerifiesWithoutSource() throws {
        let f=try Fixture(); defer{f.clean()}
        let before=try snapshot(f.source)
        let empty=try f.names()
        let plan=try f.plan()
        XCTAssertTrue(plan.canCreate)
        XCTAssertEqual(try f.names(),empty,"Preflight must write nothing")
        var progress:[JobProgress]=[]
        let job=try JobEngine().create(preflight:plan){ progress.append($0) }
        XCTAssertEqual(job.status,.completed)
        XCTAssertTrue(job.finalSourceVerified)
        XCTAssertEqual(job.archives.count,2)
        XCTAssertEqual(try snapshot(f.source),before)
        XCTAssertEqual(progress.last?.fraction,1)
        XCTAssertTrue(progress.dropLast().allSatisfy{$0.fraction<1})
        XCTAssertEqual(progress.last?.verifiedBytes,plan.totalBytes)
        XCTAssertEqual(progress.last?.bytesWritten,job.archives.reduce(0){$0+($1.actualBytes ?? 0)})
        XCTAssertEqual(progress.last?.bytesRead,plan.totalBytes*4+job.archives.reduce(0){$0+($1.actualBytes ?? 0)})
        for name in JobEngine.reportNames { XCTAssertTrue(try f.names().contains(name)) }
        XCTAssertFalse(try f.names().contains(where:{$0.hasSuffix(".partial")}))
        try FileManager.default.moveItem(at:f.source,to:f.root.appendingPathComponent("Source-unavailable"))
        let deep=try HandoffVerifier.verify(destinationURL:f.destination,deep:true)
        XCTAssertTrue(deep.passed)
        XCTAssertEqual(deep.checkedFiles,6)
        let quick=try HandoffVerifier.verify(destinationURL:f.destination,deep:false)
        XCTAssertTrue(quick.passed)
        XCTAssertEqual(quick.checkedFiles,0)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/shasum");process.arguments=["-a","256","-c","SHA256SUMS.txt"];process.currentDirectoryURL=f.destination
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
    }
    func testCancellationPreservesVerifiedZIPAndResumeRechecksIt() throws {
        let f=try Fixture();defer{f.clean()}
        let before=try snapshot(f.source), token=CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight:f.plan(),cancellation:token){ p in
            if p.verifiedArchives==1 {token.cancel()}
        })
        let interrupted=try JobEngine.loadState(destinationURL:f.destination)
        XCTAssertEqual(interrupted.status,.interrupted)
        XCTAssertTrue(try f.names().contains("FOOTAGE_001.zip"))
        XCTAssertFalse(try f.names().contains("HANDOFF_MANIFEST.json"))
        let firstZIP=try Data(contentsOf:f.destination.appendingPathComponent("FOOTAGE_001.zip"))
        let recovered=try JobEngine().resume(destinationURL:f.destination)
        XCTAssertEqual(recovered.status,.completed)
        XCTAssertTrue(recovered.events.contains{$0.message.contains("archive SHA-256 and every member reverified")})
        XCTAssertEqual(try Data(contentsOf:f.destination.appendingPathComponent("FOOTAGE_001.zip")),firstZIP)
        XCTAssertEqual(try snapshot(f.source),before)
    }
    func testCancelledPartialIsRetainedAndRebuiltOnResume() throws {
        let f=try Fixture();defer{f.clean()}
        let token=CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight:f.plan(),cancellation:token){ p in
            if p.operation.contains("Verifying archived members") {token.cancel()}
        })
        XCTAssertTrue(try f.names().contains(".FOOTAGE_001.zip.partial"))
        XCTAssertFalse(try f.names().contains("FOOTAGE_001.zip"))
        let job=try JobEngine().resume(destinationURL:f.destination)
        XCTAssertEqual(job.status,.completed)
        XCTAssertTrue(try f.names().contains(where:{$0.contains(".partial.interrupted-")}))
    }
    func testSourceChangeAfterAnalysisBlocksBeforeAnyDestinationWrites() throws {
        let f=try Fixture();defer{f.clean()}
        let plan=try f.plan()
        try Data("changed".utf8).write(to:f.source.appendingPathComponent("A001C001.mov"))
        XCTAssertThrowsError(try JobEngine().create(preflight:plan))
        XCTAssertEqual(try f.names(),[])
    }
    func testMidJobSourceMutationNeverPublishesSuccessAndPersistsFailure() throws {
        let f=try Fixture();defer{f.clean()}
        let plan=try f.plan()
        let changingPath=plan.archives[0].files[0].relativePath
        var changed=false
        XCTAssertThrowsError(try JobEngine().create(preflight:plan){ p in
            if p.operation.contains("Writing ZIP64"), !changed {
                changed=true
                try! Data("modified original".utf8).write(to:f.source.appendingPathComponent(changingPath))
            }
        })
        XCTAssertTrue(changed)
        let failed=try JobEngine.loadState(destinationURL:f.destination)
        XCTAssertEqual(failed.status,.failed)
        XCTAssertFalse(failed.finalSourceVerified)
        XCTAssertFalse(try f.names().contains("HANDOFF_MANIFEST.json"))
        XCTAssertFalse(try f.names().contains("FOOTAGE_001.zip"))
    }
    func testFinalSourceRehashCatchesLateMutation() throws {
        let f=try Fixture();defer{f.clean()}
        var changed=false
        XCTAssertThrowsError(try JobEngine().create(preflight:f.plan()){ p in
            if p.operation.contains("Final source stability"),!changed {
                changed=true
                try! Data("late modification".utf8).write(to:f.source.appendingPathComponent("A001C001.mov"))
            }
        })
        XCTAssertTrue(changed)
        XCTAssertEqual(try f.names().filter{$0.hasSuffix(".zip")}.count,2,"Independently verified archives are preserved")
        XCTAssertFalse(try f.names().contains("HANDOFF_MANIFEST.json"))
        XCTAssertFalse(try JobEngine.loadState(destinationURL:f.destination).finalSourceVerified)
    }
    func testCorruptExistingArchiveFailsDeliveryAndResumeWillNotOverwriteIt() throws {
        let f=try Fixture();defer{f.clean()}
        let job=try JobEngine().create(preflight:f.plan())
        let zip=f.destination.appendingPathComponent(job.archives[0].plan.name)
        var corrupted=try Data(contentsOf:zip);corrupted[80] ^= 0xff;try corrupted.write(to:zip)
        let report=try HandoffVerifier.verify(destinationURL:f.destination,deep:true)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains{$0.contains("mismatch")})
        XCTAssertThrowsError(try JobEngine().resume(destinationURL:f.destination))
        XCTAssertEqual(try Data(contentsOf:zip),corrupted)
    }
    func testDeliveryReportsMissingAndUnexpectedArchives() throws {
        let f=try Fixture();defer{f.clean()}
        let job=try JobEngine().create(preflight:f.plan())
        try FileManager.default.moveItem(at:f.destination.appendingPathComponent(job.archives[0].plan.name),to:f.destination.appendingPathComponent("SURPRISE.zip"))
        let report=try HandoffVerifier.verify(destinationURL:f.destination)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains{$0.contains("Missing archive")})
        XCTAssertTrue(report.issues.contains{$0.contains("Unexpected archive")})
    }
    func testRecoveryRejectsDifferentDestinationObject() throws {
        let f=try Fixture();defer{f.clean()}
        let token=CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight:f.plan(),cancellation:token){p in if p.verifiedArchives==1{token.cancel()} })
        let moved=f.root.appendingPathComponent("Original-delivery")
        try FileManager.default.moveItem(at:f.destination,to:moved)
        try FileManager.default.copyItem(at:moved,to:f.destination)
        XCTAssertThrowsError(try JobEngine().resume(destinationURL:f.destination))
    }
    func testRecoveryPreservesInterruptedStateWrite() throws {
        let f=try Fixture();defer{f.clean()}
        let token=CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight:f.plan(),cancellation:token){p in if p.verifiedArchives==1{token.cancel()} })
        let state=f.destination.appendingPathComponent(JobEngine.stateName)
        let pending=f.destination.appendingPathComponent(".\(JobEngine.stateName).pending")
        try FileManager.default.copyItem(at:state,to:pending)
        XCTAssertEqual(try JobEngine().resume(destinationURL:f.destination).status,.completed)
        XCTAssertTrue(try f.names().contains{$0.contains("pending.interrupted-")})
    }
    func testRecoveryOfInitialPendingStateWithoutFinalState() throws {
        let f=try Fixture();defer{f.clean()}
        let job=JobRecord(preflight:try f.plan())
        let pending=f.destination.appendingPathComponent(".\(JobEngine.stateName).pending")
        try JobEngine.encoder().encode(job).write(to:pending)
        XCTAssertEqual(try JobEngine.loadState(destinationURL:f.destination).id,job.id)
        XCTAssertEqual(try JobEngine().resume(destinationURL:f.destination).status,.completed)
    }
    func testJobLockPreventsConcurrentResume() throws {
        let f=try Fixture();defer{f.clean()}
        let token=CancellationToken()
        XCTAssertThrowsError(try JobEngine().create(preflight:f.plan(),cancellation:token){p in if p.verifiedArchives==1{token.cancel()} })
        let fd=open(f.destination.appendingPathComponent(JobEngine.lockName).path,O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd,0);defer{flock(fd,LOCK_UN);close(fd)}
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        XCTAssertThrowsError(try JobEngine().resume(destinationURL:f.destination))
    }
    func testManifestTraversalAndUnverifiedStatusAreRejected() throws {
        let f=try Fixture();defer{f.clean()}
        var job=try JobEngine().create(preflight:f.plan())
        job.archives[0].plan.name="../outside.zip"
        try JobEngine.encoder().encode(job).write(to:f.destination.appendingPathComponent(JobEngine.manifestName))
        XCTAssertThrowsError(try HandoffVerifier.verify(destinationURL:f.destination))
        job.status = .failed
        try JobEngine.encoder().encode(job).write(to:f.destination.appendingPathComponent(JobEngine.manifestName))
        XCTAssertThrowsError(try HandoffVerifier.verify(destinationURL:f.destination))
    }
    func testOversizedArchiveRequiresAcknowledgmentAndNeverSplitsPairs() throws {
        let f=try Fixture(clips:1);defer{f.clean()}
        var config=JobConfiguration(sourcePath:f.source.path,destinationPath:f.destination.path,mode:.maximumBytes(1000))
        let blocked=try Preflight.analyze(config)
        XCTAssertFalse(blocked.canCreate)
        XCTAssertTrue(blocked.archives[0].oversized)
        XCTAssertThrowsError(try JobEngine().create(preflight:blocked))
        XCTAssertEqual(try f.names(),[])
        config.acknowledgedOversized=true
        let job=try JobEngine().create(preflight:Preflight.analyze(config))
        XCTAssertEqual(job.archives.count,1)
        XCTAssertEqual(job.archives[0].plan.files.count,2)
        XCTAssertGreaterThan(job.archives[0].actualBytes!,1000)
    }
}
