import Foundation
import Darwin

/// Runs synchronously on a worker queue. Every source byte is obtained through ReadOnlySource.
public final class JobEngine {
    public static let stateName = ".zipper-job.json"
    public static let lockName = ".zipper-job.lock"
    public static let manifestName = "HANDOFF_MANIFEST.json"
    public static let reportNames = [manifestName, "HANDOFF_MANIFEST.txt", "SHA256SUMS.txt", "HANDOFF_LOG.txt"]
    public typealias ProgressHandler = (JobProgress) -> Void
    public init() {}

    public func create(preflight: PreflightReport, cancellation: CancellationToken = CancellationToken(), progress: @escaping ProgressHandler = { _ in }) throws -> JobRecord {
        guard preflight.canCreate else { throw HandoffError.blocked("Preflight has unresolved issues or oversized archives need acknowledgment.") }
        let current = try Preflight.analyze(preflight.configuration, cancellation: cancellation)
        guard current.canCreate else { throw HandoffError.blocked(current.issues.joined(separator: "\n")) }
        guard current.files == preflight.files, current.archives == preflight.archives,
              Self.sameObject(current.sourceIdentity, preflight.sourceIdentity),
              Self.sameObject(current.destination.identity, preflight.destination.identity) else {
            throw HandoffError.blocked("Source, destination, or archive plan changed after analysis. Analyze again before creating a handoff.")
        }
        let source = try ReadOnlySource(url: URL(fileURLWithPath: current.configuration.sourcePath))
        let destination = try Destination(url: URL(fileURLWithPath: current.configuration.destinationPath), source: source)
        let lock = try JobLock(destination: destination, resume: false)
        defer { lock.release() }
        var job = JobRecord(preflight: current)
        var start = AuditEvent("Preflight started (read-only).")
        start.timestamp = preflight.analyzedAt
        job.events = [start, AuditEvent("Preflight passed: \(current.packages.count) complete clip packages; \(current.archives.count) independent ZIP64 archives.")]
        try save(job, destination: destination, replace: false)
        return try execute(job: &job, source: source, destination: destination, cancellation: cancellation, progress: progress, resuming: false)
    }

    public func resume(destinationURL: URL, cancellation: CancellationToken = CancellationToken(), progress: @escaping ProgressHandler = { _ in }) throws -> JobRecord {
        let inspection = try Destination(url: destinationURL)
        var job = try Self.readRecoveryRecord(destination: inspection)
        try Self.validateRecord(job, requireComplete: false)
        let source = try ReadOnlySource(url: URL(fileURLWithPath: job.preflight.configuration.sourcePath))
        let destination = try Destination(url: destinationURL, source: source)
        guard Self.sameObject(source.identity, job.preflight.sourceIdentity),
              Self.sameObject(destination.info.identity, job.preflight.destination.identity),
              destination.info.canonicalPath == job.preflight.destination.canonicalPath else {
            throw HandoffError.blocked("The original source or destination identity has changed. Reconnected drives must match the saved directory identity; a matching drive name is insufficient.")
        }
        let lock = try JobLock(destination: destination, resume: true)
        defer { lock.release() }
        // Read again while holding the lock, never resume a stale state observed before lock acquisition.
        let lockedRecord = try Self.readRecoveryRecord(destination: destination)
        guard lockedRecord.id == job.id else { throw HandoffError.integrity("Job state changed while opening recovery.") }
        job = lockedRecord
        try preservePendingState(job: &job, destination: destination)
        try Self.validateRecord(job, requireComplete: false)
        if job.status == .completed {
            let report = try HandoffVerifier.verify(destinationURL: destinationURL, deep: true, cancellation: cancellation)
            guard report.passed else { throw HandoffError.integrity(report.issues.joined(separator: "\n")) }
            return job
        }
        try source.validateSnapshot(job.preflight.files)
        job.status = .running
        job.failure = nil
        job.finalSourceVerified = false
        job.events.append(AuditEvent("Resume started. Revalidating original directory identities, source hashes, and every existing archive hash."))
        try save(job, destination: destination)
        return try execute(job: &job, source: source, destination: destination, cancellation: cancellation, progress: progress, resuming: true)
    }

    private func execute(job: inout JobRecord, source: ReadOnlySource, destination: Destination, cancellation: CancellationToken, progress: @escaping ProgressHandler, resuming: Bool) throws -> JobRecord {
        let started = Date()
        var p = JobProgress(totalArchives: job.archives.count, archiveStates: Dictionary(uniqueKeysWithValues: job.archives.map { ($0.plan.name, $0.state) }))
        let payload = job.preflight.totalBytes
        let plannedArchiveBytes = job.archives.reduce(UInt64(0)) { $0 + $1.plan.predictedBytes }
        let expectedWork = Double(payload) * 3 + Double(plannedArchiveBytes) * 2 // source hash + write-read + member verify + ZIP hash + final source hash
        var work: Double = 0
        var currentIndex: Int?
        var verifiedOutputIdentities: [String: FileIdentity] = [:]
        var lastEmission = Date.distantPast
        func emit(_ force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastEmission) >= 0.10 else { return }
            lastEmission = now
            p.elapsed = now.timeIntervalSince(started)
            p.fraction = min(0.995, expectedWork == 0 ? 0 : work / expectedWork)
            progress(p)
        }
        do {
            try cancellation.check()
            try destination.validateIdentity()
            try source.validateSnapshot(job.preflight.files)
            let existingNames = Set(try destination.names())
            let minimumRemaining = resuming ? job.archives.filter { !existingNames.contains($0.plan.name) && !($0.sha256 != nil && existingNames.contains(".\($0.plan.name).partial")) }.reduce(UInt64(0)) { $0 + $1.plan.predictedBytes } : plannedArchiveBytes
            try checkCapacity(destination, needed: minimumRemaining + Self.safetyMargin(plannedArchiveBytes))
            job.events.append(AuditEvent("Source hashing started. SHA-256 is computed by streaming every source file."))
            var hashes: [String: String] = [:]
            for index in job.archives.indices {
                currentIndex = index
                let wasVerified = job.archives[index].state == .verified
                if !wasVerified { job.archives[index].state = .hashingSource }
                p.archiveStates[job.archives[index].plan.name] = .hashingSource
                p.currentArchive = job.archives[index].plan.name
                p.operation = "Hashing source"
                try save(job, destination: destination)
                emit(true)
                for file in job.archives[index].plan.files {
                    p.currentFile = file.relativePath
                    let digest = try source.hash(file, cancellation: cancellation) { bytes in
                        p.bytesRead += bytes; work += Double(bytes); emit()
                    }
                    if let expected = file.sha256, digest != expected {
                        throw HandoffError.integrity("Source SHA-256 changed: \(file.relativePath). The saved handoff cannot be resumed with different source bytes.")
                    }
                    hashes[file.relativePath] = digest
                }
                Self.applyHashes(hashes, to: &job)
                if !wasVerified { job.archives[index].state = .queued }
                try save(job, destination: destination)
            }
            currentIndex = nil
            job.events.append(AuditEvent("Source hashing completed for \(hashes.count) files."))
            try save(job, destination: destination)
            for index in job.archives.indices {
                currentIndex = index
                try cancellation.check()
                try destination.validateIdentity()
                let plan = job.archives[index].plan
                let partial = ".\(plan.name).partial"
                p.currentArchive = plan.name
                let names = try destination.names()
                if names.contains(plan.name) {
                    guard resuming, let expected = job.archives[index].sha256, let expectedSize = job.archives[index].actualBytes else {
                        throw HandoffError.blocked("Existing output has no saved verification evidence: \(plan.name). It will not be overwritten.")
                    }
                    p.operation = "Rechecking verified archive"
                    p.archiveStates[plan.name] = .hashingArchive
                    emit(true)
                    let actual = try ZIPArchive.hash(name: plan.name, destination: destination, cancellation: cancellation) { bytes in p.bytesRead += bytes; work += Double(bytes); emit() }
                    guard actual.sha256 == expected, actual.bytes == expectedSize else {
                        throw HandoffError.integrity("Saved archive no longer matches its SHA-256: \(plan.name). It has been invalidated and will not be replaced automatically.")
                    }
                    let verifiedIdentity = try ZIPArchive.verify(name: plan.name, files: plan.files, destination: destination, cancellation: cancellation) { file, bytes in
                        p.currentFile=file; p.bytesRead += bytes; p.verifiedBytes += bytes; work += Double(bytes); emit()
                    }
                    guard verifiedIdentity == actual.identity else { throw HandoffError.integrity("Archive identity changed between recovery hash and member verification: \(plan.name).") }
                    work += Double(plan.predictedBytes) // writing was durably completed before this run
                    job.archives[index].state = .verified
                    job.archives[index].failure = nil
                    p.archiveStates[plan.name] = .verified
                    verifiedOutputIdentities[plan.name] = actual.identity
                    p.verifiedArchives += 1
                    job.events.append(AuditEvent("Resume: \(plan.name) archive SHA-256 and every member reverified."))
                    try save(job, destination: destination)
                    emit(true)
                    continue
                }
                if resuming, names.contains(partial), let expected = job.archives[index].sha256, let expectedSize = job.archives[index].actualBytes {
                    p.operation = "Recovering verified partial"
                    emit(true)
                    let actual = try ZIPArchive.hash(name: partial, destination: destination, cancellation: cancellation) { bytes in p.bytesRead += bytes; work += Double(bytes); emit() }
                    guard actual.sha256 == expected, actual.bytes == expectedSize else { throw HandoffError.integrity("Recovery partial does not match its saved archive hash: \(partial). Artifact preserved.") }
                    let verifiedIdentity = try ZIPArchive.verify(name: partial, files: plan.files, destination: destination, cancellation: cancellation) { file, bytes in p.currentFile=file; p.bytesRead += bytes; p.verifiedBytes += bytes; work += Double(bytes); emit() }
                    guard verifiedIdentity == actual.identity else { throw HandoffError.integrity("Partial identity changed during recovery: \(partial).") }
                    try cancellation.check()
                    try destination.renameExclusive(from: partial, to: plan.name, expectedIdentity: actual.identity)
                    try destination.sync()
                    job.archives[index].state = .verified
                    job.archives[index].failure = nil
                    p.archiveStates[plan.name] = .verified; p.verifiedArchives += 1
                    verifiedOutputIdentities[plan.name] = try destination.identityOf(plan.name)
                    work += Double(plan.predictedBytes)
                    job.events.append(AuditEvent("Resume: recovered \(plan.name) after rehashing and verifying the complete partial."))
                    try save(job, destination: destination)
                    emit(true)
                    continue
                }
                if names.contains(partial) {
                    guard resuming else { throw HandoffError.blocked("Incomplete output already exists: \(partial). Resume the original job or choose a new destination.") }
                    let retained = partial + ".interrupted-" + UUID().uuidString
                    try destination.renameExclusive(from: partial, to: retained)
                    job.events.append(AuditEvent("Preserved interrupted artifact as \(retained). Rebuilding this archive from stable source files."))
                }
                job.archives[index].sha256 = nil
                job.archives[index].actualBytes = nil
                job.archives[index].failure = nil
                job.archives[index].state = .writing
                p.archiveStates[plan.name] = .writing
                p.operation = "Writing ZIP64 · STORE"
                job.events.append(AuditEvent("Writing \(partial)."))
                try save(job, destination: destination)
                try checkCapacity(destination, needed: plan.predictedBytes + Self.safetyMargin(plannedArchiveBytes))
                emit(true)
                var capacityBytes: UInt64 = 0
                _ = try ZIPArchive.write(plan: plan, source: source, destination: destination, partialName: partial, cancellation: cancellation, sourceProgress: { file, bytes in
                    p.currentFile=file; p.bytesRead += bytes
                }) { file, bytes in
                    p.currentFile=file; p.bytesWritten += bytes; work += Double(bytes); capacityBytes += bytes
                    if capacityBytes >= 64 * 1_024 * 1_024 {
                        try self.checkCapacity(destination, needed: Self.safetyMargin(plannedArchiveBytes))
                        capacityBytes = 0
                    }
                    emit()
                }
                job.archives[index].state = .verifyingContents
                p.archiveStates[plan.name] = .verifyingContents
                p.operation = "Verifying archived members · SHA-256"
                job.events.append(AuditEvent("Archive closed and flushed. Independently reopening \(partial) and hashing every member."))
                try save(job, destination: destination)
                emit(true)
                let verifiedIdentity = try ZIPArchive.verify(name: partial, files: plan.files, destination: destination, cancellation: cancellation) { file, bytes in
                    p.currentFile=file; p.bytesRead += bytes; p.verifiedBytes += bytes; work += Double(bytes); emit()
                }
                job.archives[index].state = .hashingArchive
                p.archiveStates[plan.name] = .hashingArchive
                p.operation = "Hashing complete archive · SHA-256"
                job.events.append(AuditEvent("Member verification passed for \(plan.name). Computing the complete ZIP SHA-256."))
                try save(job, destination: destination)
                emit(true)
                let result = try ZIPArchive.hash(name: partial, destination: destination, cancellation: cancellation) { bytes in p.bytesRead += bytes; work += Double(bytes); emit() }
                guard result.identity == verifiedIdentity else { throw HandoffError.integrity("Archive identity changed between member verification and archive hashing: \(plan.name).") }
                guard result.bytes == plan.predictedBytes else { throw HandoffError.integrity("Archive size differs from its exact ZIP64 plan: \(plan.name).") }
                if case .maximumBytes(let ceiling) = job.preflight.configuration.mode, result.bytes > ceiling, !plan.oversized {
                    throw HandoffError.integrity("Archive exceeds the configured hard ceiling: \(plan.name). It remains incomplete.")
                }
                job.archives[index].sha256 = result.sha256
                job.archives[index].actualBytes = result.bytes
                // Persist successful verification before promotion; recovery never trusts this record without rehashing.
                job.events.append(AuditEvent("Verification evidence recorded for \(plan.name): \(result.sha256)."))
                try save(job, destination: destination)
                try cancellation.check()
                try destination.renameExclusive(from: partial, to: plan.name, expectedIdentity: result.identity)
                try destination.sync()
                job.archives[index].state = .verified
                p.archiveStates[plan.name] = .verified
                verifiedOutputIdentities[plan.name] = try destination.identityOf(plan.name)
                p.verifiedArchives += 1
                job.events.append(AuditEvent("Verified archive promoted atomically: \(plan.name)."))
                try save(job, destination: destination)
                emit(true)
            }
            currentIndex = nil
            p.operation = "Final source stability check · SHA-256"
            p.currentArchive = "All archives verified"
            job.events.append(AuditEvent("Final source validation started: re-enumerating and rehashing all original files."))
            try save(job, destination: destination)
            emit(true)
            try source.validateSnapshot(job.preflight.files)
            for file in job.preflight.files {
                p.currentFile = file.relativePath
                let digest = try source.hash(file, cancellation: cancellation) { bytes in p.bytesRead += bytes; work += Double(bytes); emit() }
                guard digest == file.sha256 else { throw HandoffError.integrity("Final source hash mismatch: \(file.relativePath). The job is not a verified handoff.") }
            }
            try source.validateSnapshot(job.preflight.files)
            try cancellation.check()
            try destination.validateIdentity()
            guard verifiedOutputIdentities.count == job.archives.count else { throw HandoffError.integrity("Not every archive has current verification evidence.") }
            for (name, identity) in verifiedOutputIdentities {
                guard try destination.identityOf(name) == identity else { throw HandoffError.integrity("Previously verified archive changed before final completion: \(name).") }
            }
            let expectedZIPs = Set(job.archives.map { $0.plan.name })
            guard Set(try destination.names().filter { $0.lowercased().hasSuffix(".zip") }) == expectedZIPs else { throw HandoffError.integrity("Unexpected or missing ZIPs appeared during this job. Review the destination before handoff.") }
            job.finalSourceVerified = true
            if job.completedAt == nil { job.completedAt = Date() }
            job.events.append(AuditEvent("Final source hashes match all archived members. Publishing delivery manifests."))
            try save(job, destination: destination)
            p.operation = "Publishing verified delivery reports"
            p.currentFile = Self.manifestName
            emit(true)
            try cancellation.check()
            try source.validateSnapshot(job.preflight.files)
            for (name, identity) in verifiedOutputIdentities {
                guard try destination.identityOf(name) == identity else { throw HandoffError.integrity("Archive changed immediately before report publication: \(name).") }
            }
            var completed = job
            completed.status = .completed
            completed.failure = nil
            completed.events.append(AuditEvent("Verified handoff ready. All source files and independent archives verified."))
            try publishReports(completed, destination: destination, resuming: resuming)
            try cancellation.check()
            try source.validateSnapshot(job.preflight.files)
            for (name, identity) in verifiedOutputIdentities {
                guard try destination.identityOf(name) == identity else { throw HandoffError.integrity("Verified archive changed while delivery reports were being published: \(name).") }
            }
            guard Set(try destination.names().filter { $0.lowercased().hasSuffix(".zip") }) == expectedZIPs else { throw HandoffError.integrity("Archive directory changed during report publication.") }
            // This atomic completed manifest is the public delivery commit marker.
            // Before it appears, every partial report set remains explicitly non-complete.
            try destination.writeAtomic(try Self.encoder().encode(completed), name: Self.manifestName, replace: true)
            try save(completed, destination: destination)
            try destination.sync()
            job = completed
            p.operation = "Verified handoff ready"
            p.currentFile = ""
            p.elapsed = Date().timeIntervalSince(started)
            p.fraction = 1
            progress(p)
            return job
        } catch {
            let cancelled = (error as? HandoffError) == .cancelled
            job.status = cancelled ? .interrupted : .failed
            job.finalSourceVerified = false
            job.failure = error.localizedDescription
            if let index = currentIndex {
                job.archives[index].state = cancelled ? .interrupted : .failed
                job.archives[index].failure = error.localizedDescription
            }
            job.events.append(AuditEvent("\(cancelled ? "Interrupted" : "Failed"): \(error.localizedDescription)"))
            // A removed/read-only destination can make persistence impossible; its last durable phase remains non-successful.
            do { try save(job, destination: destination) }
            catch { throw HandoffError.io("\(job.failure ?? "Job stopped.")\nThe destination also rejected the failure-state update: \(error.localizedDescription). The last durable job state must be recovered and reverified.") }
            throw error
        }
    }

    private func checkCapacity(_ destination: Destination, needed: UInt64) throws {
        try destination.validateIdentity()
        let available = try destination.availableBytes()
        guard available >= needed else { throw HandoffError.io("Destination capacity is too low to continue safely. Need at least \(Self.bytes(needed)); \(Self.bytes(available)) is available. Verified archives are preserved.") }
    }
    public static func safetyMargin(_ bytes: UInt64) -> UInt64 { max(64 * 1_024 * 1_024, bytes / 20) }
    private func save(_ job: JobRecord, destination: Destination, replace: Bool = true) throws {
        try destination.writeAtomic(try Self.encoder().encode(job), name: Self.stateName, replace: replace)
    }
    private static func applyHashes(_ hashes: [String: String], to job: inout JobRecord) {
        func hashed(_ file: SourceFile) -> SourceFile { var result=file; result.sha256=hashes[file.relativePath] ?? file.sha256; return result }
        func package(_ p: ClipPackage) -> ClipPackage { ClipPackage(basename: p.basename, media: hashed(p.media), xml: hashed(p.xml)) }
        job.preflight.files = job.preflight.files.map(hashed)
        job.preflight.packages = job.preflight.packages.map(package)
        for index in job.archives.indices {
            job.archives[index].plan.packages = job.archives[index].plan.packages.map(package)
        }
        job.preflight.archives = job.archives.map(\.plan)
    }
    static func encoder() -> JSONEncoder { let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e }
    static func decoder() -> JSONDecoder { let d=JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func sameObject(_ a: FileIdentity, _ b: FileIdentity) -> Bool { a.device == b.device && a.inode == b.inode }
    public static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .decimal) }
    public static func loadState(destinationURL: URL) throws -> JobRecord { try readRecoveryRecord(destination: Destination(url: destinationURL)) }
    private static func readRecoveryRecord(destination: Destination) throws -> JobRecord {
        let names = try destination.names()
        if names.contains(stateName) { return try readRecord(name: stateName, destination: destination) }
        if names.contains(".\(stateName).pending") { return try readRecord(name: ".\(stateName).pending", destination: destination) }
        throw HandoffError.blocked("No recoverable Zipper job state exists in this destination.")
    }
    private func preservePendingState(job: inout JobRecord, destination: Destination) throws {
        let names = Set(try destination.names())
        for name in [Self.stateName] + Self.reportNames {
            let pending = ".\(name).pending"
            if names.contains(pending) {
                let retained = pending + ".interrupted-" + UUID().uuidString
                try destination.renameExclusive(from: pending, to: retained)
                job.events.append(AuditEvent("Preserved interrupted state/report write as \(retained)."))
            }
        }
    }
    static func readRecord(name: String, destination: Destination) throws -> JobRecord {
        let fd = try destination.openRead(name)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 64 * 1_024 * 1_024 else { throw HandoffError.integrity("Job manifest is empty, unreadable, or exceeds the 64 MiB safety limit.") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw HandoffError.io("Cannot read \(name): \(String(cString: strerror(errno))).") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 64 * 1_024 * 1_024 else { throw HandoffError.integrity("Manifest grew beyond the safety limit while being read.") }
        }
        guard data.count == info.st_size else { throw HandoffError.integrity("Manifest changed size while being read: \(name).") }
        var after = stat()
        guard fstat(fd, &after) == 0, fileIdentity(after) == fileIdentity(info),
              try destination.identityOf(name) == fileIdentity(info) else { throw HandoffError.integrity("Manifest changed identity or metadata while being read: \(name).") }
        do { return try decoder().decode(JobRecord.self, from: data) }
        catch { throw HandoffError.integrity("Cannot decode \(name). Use the original, complete Zipper manifest. \(error.localizedDescription)") }
    }
    static func validateRecord(_ job: JobRecord, requireComplete: Bool) throws {
        guard job.schemaVersion == 1, job.application == "Zipper", !job.archives.isEmpty,
              !job.preflight.files.isEmpty, job.preflight.issues.isEmpty else { throw HandoffError.integrity("Unsupported or invalid handoff manifest.") }
        let completeEvidenceRequired = requireComplete || job.status == .completed
        if completeEvidenceRequired {
            guard job.status == .completed, job.finalSourceVerified, job.completedAt != nil, job.failure == nil else {
                throw HandoffError.integrity("This delivery has no completed, source-verified manifest.")
            }
        }
        func validLeaf(_ name: String) -> Bool { safeLeaf(name) && !name.contains(":") && name.utf8.count <= 255 }
        let names = job.archives.map { $0.plan.name }
        guard Set(names.map(collisionKey)).count == names.count,
              names.allSatisfy({ validLeaf($0) && $0.hasSuffix(".zip") }) else { throw HandoffError.integrity("Manifest contains duplicate or unsafe archive names.") }
        let files = job.preflight.files
        // Validate raw decoded numbers before invoking any aggregate/computed model property.
        // In particular preflight.packages is separately decoded and must not be allowed to
        // carry unrelated sizes that can overflow ClipPackage.totalSize in the interface.
        guard files.allSatisfy({ $0.size <= UInt64(Int64.max) }),
              files.reduce(UInt64(0), { saturatingAdd($0, $1.size) }) <= UInt64(Int64.max),
              job.archives.allSatisfy({ $0.plan.predictedBytes <= UInt64(Int64.max) }) else { throw HandoffError.integrity("Manifest byte counts exceed supported integer limits.") }
        guard Set(files.map { collisionKey($0.relativePath) }).count == files.count,
              files.allSatisfy({ file in
                  let ext = (file.relativePath as NSString).pathExtension.lowercased()
                  let basename = (file.relativePath as NSString).deletingPathExtension
                  return validLeaf(file.relativePath) && !file.basename.isEmpty &&
                      Array(file.basename.utf8) == Array(basename.utf8) &&
                      ((file.kind == .media && SupportedMedia.extensions.contains(ext)) || (file.kind == .xml && ext == "xml")) &&
                      (file.sha256 == nil || isSHA256(file.sha256))
              }) else { throw HandoffError.integrity("Manifest contains duplicate, unsafe, or unsupported member paths or inconsistent basenames.") }
        let allMembers = job.archives.flatMap { $0.plan.files }
        guard allMembers.count == files.count,
              Set(allMembers.map(\.relativePath)).count == files.count,
              Dictionary(uniqueKeysWithValues: allMembers.map { ($0.relativePath,$0) }) == Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath,$0) }),
              job.preflight.archives == job.archives.map(\.plan) else { throw HandoffError.integrity("Manifest archive membership does not account for every source file exactly once.") }
        let packages = job.archives.flatMap { $0.plan.packages }
        func ordered(_ values: [ClipPackage]) -> [ClipPackage] { values.sorted { $0.basename.utf8.lexicographicallyPrecedes($1.basename.utf8) } }
        guard Set(packages.map { collisionKey($0.basename) }).count == packages.count,
              ordered(job.preflight.packages) == ordered(packages) else {
            throw HandoffError.integrity("Preflight package inventory conflicts with the actual archive partition.")
        }
        if let statistics = job.deliveryStatistics, statistics != DeliveryStatistics(preflight: job.preflight) {
            throw HandoffError.integrity("Manifest delivery counts disagree with its source inventory and archive partition.")
        }
        for archive in job.archives {
            guard !archive.plan.packages.isEmpty,
                  archive.plan.packages.allSatisfy({ package in
                      package.media.kind == .media && package.xml.kind == .xml &&
                          Array(package.media.basename.utf8) == Array(package.basename.utf8) &&
                          Array(package.xml.basename.utf8) == Array(package.basename.utf8)
                  }),
                  archive.plan.predictedBytes == ZIPArchive.predictedSize(files: archive.plan.files),
                  archive.sha256 == nil || isSHA256(archive.sha256),
                  archive.actualBytes == nil || archive.actualBytes == archive.plan.predictedBytes else {
                throw HandoffError.integrity("Invalid clip pairs, ZIP size, or verification evidence in manifest: \(archive.plan.name).")
            }
            if completeEvidenceRequired || archive.state == .verified {
                guard archive.state == .verified, isSHA256(archive.sha256), archive.actualBytes == archive.plan.predictedBytes,
                      archive.plan.files.allSatisfy({ isSHA256($0.sha256) }) else { throw HandoffError.integrity("Incomplete verification evidence for \(archive.plan.name).") }
            }
        }
        switch job.preflight.configuration.mode {
        case .archiveCount(let count):
            guard count > 0, count == job.archives.count, job.archives.allSatisfy({ !$0.plan.oversized }) else {
                throw HandoffError.integrity("Configured archive count disagrees with the actual nonempty archive partition.")
            }
        case .maximumBytes(let maximum):
            guard maximum > 0 else { throw HandoffError.integrity("Configured maximum archive size is invalid.") }
            for archive in job.archives {
                let exceedsMaximum = archive.plan.predictedBytes > maximum
                guard archive.plan.oversized == exceedsMaximum,
                      !exceedsMaximum || (archive.plan.packages.count == 1 && job.preflight.configuration.acknowledgedOversized) else {
                    throw HandoffError.integrity("Archive exceeds its configured hard ceiling without a valid indivisible-package acknowledgment: \(archive.plan.name).")
                }
            }
        }
    }
    static func safeLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func isSHA256(_ value: String?) -> Bool { guard let value, value.count == 64 else { return false }; return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func publishReports(_ job: JobRecord, destination: Destination, resuming: Bool) throws {
        try Self.validateRecord(job, requireComplete: true)
        let existing = Set(try destination.names())
        let collisions = existing.intersection(Self.reportNames)
        var replacingOwned = false
        if !collisions.isEmpty {
            guard resuming, existing.contains(Self.manifestName) else { throw HandoffError.blocked("Delivery reports already exist; they will not be replaced. Choose a fresh delivery destination.") }
            let previous = try Self.readRecord(name: Self.manifestName, destination: destination)
            guard previous.id == job.id, previous.archives.map(\.sha256) == job.archives.map(\.sha256) else { throw HandoffError.blocked("Existing delivery reports belong to different verification evidence and will not be overwritten.") }
            replacingOwned = true
        }
        var provisional = job
        provisional.status = .running
        provisional.finalSourceVerified = false
        let manifest = try Self.encoder().encode(provisional)
        let human = Self.humanReport(job)
        let sums = job.archives.map { "\($0.sha256!)  \($0.plan.name)" }.joined(separator: "\n") + "\n"
        let formatter = ISO8601DateFormatter()
        let log = job.events.map { "\(formatter.string(from: $0.timestamp))  \($0.message)" }.joined(separator: "\n") + "\n"
        // Provisional JSON establishes durable ownership but cannot pass delivery verification.
        // Completed JSON is published by execute only after all reports and final guards succeed.
        for (name, data) in [(Self.manifestName,manifest),("HANDOFF_MANIFEST.txt",Data(human.utf8)),("SHA256SUMS.txt",Data(sums.utf8)),("HANDOFF_LOG.txt",Data(log.utf8))] {
            try destination.writeAtomic(data, name: name, replace: replacingOwned && existing.contains(name))
        }
    }
    public static func humanReport(_ job: JobRecord) -> String {
        let iso = ISO8601DateFormatter()
        let files = job.preflight.files
        var lines = ["ZIPPER — VERIFIED MEDIA HANDOFF", "Application: \(job.application) \(job.applicationVersion)", "Job UUID: \(job.id.uuidString)", "Created: \(iso.string(from: job.createdAt))", "Completed: \(job.completedAt.map(iso.string) ?? "Not completed")", "Verification: \(job.status == .completed && job.finalSourceVerified ? "PASS — final source SHA-256 and every archived member match" : "NOT COMPLETE")", "Source: \(job.preflight.configuration.sourcePath)", "Destination: \(job.preflight.destination.canonicalPath)", "Source files: \(files.count)", "Media: \(files.filter { $0.kind == .media }.count)", "XML: \(files.filter { $0.kind == .xml }.count)", "Unexpected files: \(files.filter { $0.kind != .media && $0.kind != .xml }.count)", "Clip packages: \(job.preflight.packages.count)", "Total source bytes: \(job.preflight.totalBytes)", "Batching: \(job.preflight.configuration.mode.description)", "Archives: \(job.archives.count)", "Format: Independent ZIP64 / STORE", "", "SHA256SUMS.txt: shasum -a 256 -c SHA256SUMS.txt", "Hashes establish byte agreement with this manifest; they are not a digital signature.", ""]
        for archive in job.archives {
            lines.append("\(archive.plan.name) | \(archive.actualBytes ?? 0) bytes | \(archive.state.rawValue)")
            lines.append("SHA-256: \(archive.sha256 ?? "not verified")")
            for file in archive.plan.files { lines.append("  \(file.relativePath) | \(file.size) bytes | SHA-256 \(file.sha256 ?? "not hashed")") }
            lines.append("")
        }
        if !job.preflight.warnings.isEmpty { lines += ["WARNINGS"] + job.preflight.warnings + [""] }
        if let failure = job.failure { lines += ["FAILURE",failure,""] }
        return lines.joined(separator: "\n") + "\n"
    }
}

private final class JobLock {
    private var fd: Int32
    init(destination: Destination, resume: Bool) throws {
        if resume {
            if (try destination.names()).contains(JobEngine.lockName) { fd = try destination.openRead(JobEngine.lockName) }
            else { fd = try destination.createExclusive(JobEngine.lockName) }
        } else { fd = try destination.createExclusive(JobEngine.lockName) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); fd = -1; throw HandoffError.blocked("Another process holds this destination job lock. Stop that job before resuming.") }
        try destination.sync()
    }
    func release() { if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
    deinit { release() }
}
