import Foundation
import Darwin

/// Delivery verification is read-only and never requires the original card.
public enum HandoffVerifier {
    public static func verify(destinationURL: URL, deep: Bool = true, cancellation: CancellationToken = CancellationToken(), progress: (JobProgress) -> Void = { _ in }) throws -> VerificationReport {
        let destination = try Destination(url: destinationURL)
        let manifest = try readStableReport(JobEngine.manifestName, destination: destination, cancellation: cancellation)
        let job: JobRecord
        do { job = try JobEngine.decoder().decode(JobRecord.self, from: manifest.data) }
        catch { throw HandoffError.integrity("Cannot decode \(JobEngine.manifestName). Use the original, complete Zipper manifest. \(error.localizedDescription)") }
        try JobEngine.validateRecord(job, requireComplete: true)
        let started = Date()
        let names = try destination.names()
        let expectedNames = Set(job.archives.map { $0.plan.name })
        let actualNames = Set(names.filter { $0.lowercased().hasSuffix(".zip") })
        var issues = actualNames.subtracting(expectedNames).sorted().map { "Unexpected archive: \($0)." }
        issues += expectedNames.subtracting(actualNames).sorted().map { "Missing archive: \($0)." }
        var checkedIdentities = [JobEngine.manifestName: manifest.identity]
        // A completed JSON can survive interruption between individual report publications.
        // The delivery is complete only when all required reports are present and readable.
        for name in JobEngine.reportNames where name != JobEngine.manifestName {
            try cancellation.check()
            do {
                let report = try readStableReport(name, destination: destination, cancellation: cancellation)
                checkedIdentities[name] = report.identity
                guard String(data: report.data, encoding: .utf8) != nil else { throw HandoffError.integrity("Delivery report is not valid UTF-8: \(name).") }
                if name == "SHA256SUMS.txt" {
                    let expected = job.archives.map { "\($0.sha256!)  \($0.plan.name)" }.joined(separator: "\n") + "\n"
                    guard report.data == Data(expected.utf8) else { throw HandoffError.integrity("SHA256SUMS.txt does not match the archive hashes and names in the manifest.") }
                }
            } catch {
                if (error as? HandoffError) == .cancelled { throw error }
                issues.append("Required delivery report is missing or invalid: \(name). \(error.localizedDescription)")
            }
        }
        var p = JobProgress(operation: "Verifying existing handoff", totalArchives: job.archives.count)
        var checkedFiles = 0
        let totalBytes = job.archives.reduce(Double(0)) { $0 + Double($1.actualBytes ?? 0) } + (deep ? Double(job.preflight.totalBytes) : 0)
        var lastEmission = Date.distantPast
        func emit(_ force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastEmission) >= 0.1 else { return }
            lastEmission = now
            p.elapsed = now.timeIntervalSince(started)
            p.fraction = min(0.995, totalBytes == 0 ? 0 : Double(p.bytesRead) / totalBytes)
            progress(p)
        }
        for archive in job.archives {
            try cancellation.check()
            guard actualNames.contains(archive.plan.name) else { p.archiveStates[archive.plan.name] = .failed; continue }
            p.currentArchive = archive.plan.name
            p.currentFile = archive.plan.name
            p.operation = "Checking archive SHA-256"
            p.archiveStates[archive.plan.name] = .hashingArchive
            emit(true)
            do {
                let hash = try ZIPArchive.hash(name: archive.plan.name, destination: destination, cancellation: cancellation) { bytes in p.bytesRead += bytes; emit() }
                guard hash.sha256 == archive.sha256, hash.bytes == archive.actualBytes else { throw HandoffError.integrity("Archive SHA-256 or size mismatch: \(archive.plan.name).") }
                if deep {
                    p.operation = "Deep verification · every archived member"
                    p.archiveStates[archive.plan.name] = .verifyingContents
                    emit(true)
                    let identity = try ZIPArchive.verify(name: archive.plan.name, files: archive.plan.files, destination: destination, cancellation: cancellation) { file, bytes in p.currentFile=file; p.bytesRead += bytes; p.verifiedBytes += bytes; emit() }
                    guard identity == hash.identity else { throw HandoffError.integrity("Archive changed between SHA-256 and deep verification: \(archive.plan.name).") }
                    checkedFiles += archive.plan.files.count
                }
                checkedIdentities[archive.plan.name] = hash.identity
                p.archiveStates[archive.plan.name] = .verified
                p.verifiedArchives += 1
            } catch {
                if (error as? HandoffError) == .cancelled { throw error }
                issues.append(error.localizedDescription)
                p.archiveStates[archive.plan.name] = .failed
            }
            emit(true)
        }
        try cancellation.check()
        try destination.validateIdentity()
        let endNames = Set(try destination.names().filter { $0.lowercased().hasSuffix(".zip") })
        if endNames != actualNames { issues.append("Archive directory changed during verification. Run the delivery check again.") }
        // Pin every earlier result until the complete delivery check finishes. An archive
        // checked first must not be allowed to change while later archives are consumed.
        for (name, expected) in checkedIdentities.sorted(by: { $0.key < $1.key }) {
            try cancellation.check()
            do {
                guard try namedIdentity(name, destination: destination) == expected else {
                    throw HandoffError.integrity("Delivery file changed after it was checked: \(name). Run the delivery check again.")
                }
            } catch {
                if expectedNames.contains(name), p.archiveStates[name] == .verified {
                    p.archiveStates[name] = .failed
                    p.verifiedArchives -= 1
                    if deep { checkedFiles -= job.archives.first { $0.plan.name == name }!.plan.files.count }
                }
                issues.append(error.localizedDescription)
            }
        }
        try cancellation.check()
        p.operation = issues.isEmpty ? "Delivery verification passed" : "Delivery verification failed"
        p.currentFile = ""
        p.elapsed = Date().timeIntervalSince(started)
        p.fraction = issues.isEmpty ? 1 : min(0.995,p.fraction)
        progress(p)
        return VerificationReport(passed: issues.isEmpty, checkedArchives: p.verifiedArchives, checkedFiles: checkedFiles, issues: issues, deep: deep)
    }

    private static func namedIdentity(_ name: String, destination: Destination) throws -> FileIdentity {
        let fd = try destination.openRead(name)
        defer { Darwin.close(fd) }
        return fileIdentity(try descriptorStatus(fd, context: name))
    }

    private static func readStableReport(_ name: String, destination: Destination, cancellation: CancellationToken) throws -> (data: Data, identity: FileIdentity) {
        let fd = try destination.openRead(name)
        defer { Darwin.close(fd) }
        let before = fileIdentity(try descriptorStatus(fd, context: name))
        let limit = 64 * 1_024 * 1_024
        guard before.size > 0, before.size <= UInt64(limit) else {
            throw HandoffError.integrity("Delivery report is empty or exceeds the 64 MiB safety limit: \(name).")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellation.check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw fileSystemError("Cannot read delivery report", name) }
            if count == 0 { break }
            guard count <= limit - data.count else { throw HandoffError.integrity("Delivery report grew beyond the safety limit: \(name).") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == before.size,
              fileIdentity(try descriptorStatus(fd, context: name)) == before,
              try namedIdentity(name, destination: destination) == before else {
            throw HandoffError.integrity("Delivery report changed while being read: \(name).")
        }
        return (data, before)
    }
}
