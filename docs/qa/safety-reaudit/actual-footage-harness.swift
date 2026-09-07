import Foundation
import HandoffCore

func note(_ text: String) {
    FileHandle.standardOutput.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8))
}
let sourceURL = URL(fileURLWithPath: "/Users/atiliobarreda/Desktop/video/VISUAL DEALERS/VISUAL DEALERS/NYC/CAM 1/XDROOT/Clip")
let root = URL(fileURLWithPath: "/Users/atiliobarreda/Desktop/software/personal/zipper/.build")
let destination = root.appendingPathComponent("actual-footage-qualification-" + UUID().uuidString)
let evidence = URL(fileURLWithPath: "/Users/atiliobarreda/Desktop/software/personal/zipper/docs/qa/safety-reaudit")
do {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data(destination.path.utf8).write(to: root.appendingPathComponent("actual-footage-qualification-path.txt"), options: .atomic)
    let before = try ReadOnlySource(url: sourceURL).scan()
    let plan = try Preflight.analyze(JobConfiguration(sourcePath: sourceURL.path, destinationPath: destination.path, prefix: "CAM1_AUDIT", mode: .archiveCount(8)))
    guard plan.canCreate, plan.files.count == 281, plan.packages.count == 95 else {
        throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: plan.issues.joined(separator: "\n")])
    }
    guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else { fatalError("Preflight wrote output") }
    note("PREFLIGHT PASS: \(plan.files.count) files, \(plan.totalBytes) bytes. Destination: \(destination.path)")
    var last = Date.distantPast
    func progress(_ p: JobProgress) {
        if Date().timeIntervalSince(last) > 15 {
            last = Date(); note("\(p.operation) | \(p.currentFile) | \(Int(p.fraction * 100))% | \(p.verifiedArchives)/\(p.totalArchives) archives")
        }
    }
    let job = try JobEngine().create(preflight: plan, progress: progress)
    guard job.status == .completed, job.finalSourceVerified else { fatalError("Incomplete creation") }
    note("CREATE PASS. Running independent deep delivery verification.")
    last = .distantPast
    let verified = try HandoffVerifier.verify(destinationURL: destination, progress: progress)
    guard verified.passed, verified.checkedFiles == 281, verified.checkedArchives == 8 else { fatalError("Deep verification failed: \(verified.issues)") }
    let after = try ReadOnlySource(url: sourceURL).scan()
    guard before == after else { fatalError("Source metadata changed") }
    let summary: [String: Any] = ["source": sourceURL.path, "destination": destination.path, "source_bytes": plan.totalBytes, "source_files": 281, "clip_packages": 95, "archives": 8, "creation_completed": true, "deep_reverification_passed": true, "source_metadata_unchanged": true, "application_version": job.applicationVersion, "completed_at": ISO8601DateFormatter().string(from: Date()), "limits": "Actual APFS folder, release HandoffCore engine; no physical media disconnect or power-loss test, no codec decode or full-card reconstruction."]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted,.sortedKeys]).write(to: evidence.appendingPathComponent("actual-footage-handoff.json"), options: .atomic)
    note("ALL ACTUAL-FOOTAGE CHECKS PASSED")
} catch {
    note("AUDIT FAILED: \(error.localizedDescription)")
    exit(1)
}
