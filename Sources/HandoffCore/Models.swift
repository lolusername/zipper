import Foundation

public enum HandoffError: Error, LocalizedError, Equatable {
    case blocked(String), io(String), integrity(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .blocked(let text), .io(let text), .integrity(let text): return text
        case .cancelled: return "Job cancelled safely. Verified archives are preserved; incomplete output remains marked .partial."
        }
    }
}
public struct FileIdentity: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64
    public init(device: UInt64, inode: UInt64, size: UInt64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64) {
        self.device=device; self.inode=inode; self.size=size; self.modifiedSeconds=modifiedSeconds; self.modifiedNanoseconds=modifiedNanoseconds; self.changedSeconds=changedSeconds; self.changedNanoseconds=changedNanoseconds
    }
}
public enum SourceKind: String, Codable, Sendable { case media, xml, bim, unexpected, hidden, directory, symlink }
public struct SourceFile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var basename: String
    public var kind: SourceKind
    public var identity: FileIdentity
    public var sha256: String?
    public var size: UInt64 { identity.size }
    public init(relativePath: String, basename: String, kind: SourceKind, identity: FileIdentity, sha256: String? = nil) {
        self.relativePath=relativePath; self.basename=basename; self.kind=kind; self.identity=identity; self.sha256=sha256
    }
    /// Swift String equality normalizes Unicode. Evidence must retain the exact
    /// UTF-8 filename bytes recorded in the source scan and written to the ZIP.
    public static func == (lhs: SourceFile, rhs: SourceFile) -> Bool {
        lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8) &&
            lhs.basename.utf8.elementsEqual(rhs.basename.utf8) &&
            lhs.kind == rhs.kind && lhs.identity == rhs.identity && lhs.sha256 == rhs.sha256
    }
}
public struct ClipPackage: Codable, Equatable, Identifiable, Sendable {
    public var id: String { basename }
    public var basename: String
    public var media: SourceFile
    public var xml: SourceFile
    public var auxiliaryFiles: [SourceFile]
    public var totalSize: UInt64 { files.reduce(0) { saturatingAdd($0, $1.size) } }
    public var files: [SourceFile] { [media, xml] + auxiliaryFiles }
    public init(basename: String, media: SourceFile, xml: SourceFile, auxiliaryFiles: [SourceFile] = []) {
        self.basename=basename; self.media=media; self.xml=xml; self.auxiliaryFiles=auxiliaryFiles
    }
    private enum CodingKeys: String, CodingKey { case basename, media, xml, auxiliaryFiles }
    public init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        basename=try values.decode(String.self,forKey:.basename)
        media=try values.decode(SourceFile.self,forKey:.media)
        xml=try values.decode(SourceFile.self,forKey:.xml)
        auxiliaryFiles=try values.decodeIfPresent([SourceFile].self,forKey:.auxiliaryFiles) ?? []
    }
    public static func == (lhs: ClipPackage, rhs: ClipPackage) -> Bool {
        lhs.basename.utf8.elementsEqual(rhs.basename.utf8) && lhs.media == rhs.media &&
            lhs.xml == rhs.xml && lhs.auxiliaryFiles == rhs.auxiliaryFiles
    }
}
public enum BatchingMode: Codable, Equatable, Sendable {
    case maximumBytes(UInt64)
    case archiveCount(Int)
    public var description: String {
        switch self { case .maximumBytes(let n): return "Maximum ZIP size: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .decimal))"; case .archiveCount(let n): return "Exactly \(n) archives" }
    }
}
public struct JobConfiguration: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var destinationPath: String
    public var prefix: String
    public var mode: BatchingMode
    public var acknowledgedOversized: Bool
    public init(sourcePath: String, destinationPath: String, prefix: String = "FOOTAGE", mode: BatchingMode = .maximumBytes(25_000_000_000), acknowledgedOversized: Bool = false) {
        self.sourcePath=sourcePath; self.destinationPath=destinationPath; self.prefix=prefix; self.mode=mode; self.acknowledgedOversized=acknowledgedOversized
    }
}
public struct ArchivePlan: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var packages: [ClipPackage]
    public var predictedBytes: UInt64
    public var oversized: Bool
    public var files: [SourceFile] { packages.flatMap(\.files) }
    public init(name: String, packages: [ClipPackage], predictedBytes: UInt64, oversized: Bool = false) { self.name=name; self.packages=packages; self.predictedBytes=predictedBytes; self.oversized=oversized }
    public static func == (lhs: ArchivePlan, rhs: ArchivePlan) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.packages == rhs.packages &&
            lhs.predictedBytes == rhs.predictedBytes && lhs.oversized == rhs.oversized
    }
}
public struct DestinationInfo: Codable, Equatable, Sendable {
    public var canonicalPath: String
    public var identity: FileIdentity
    public var filesystem: String
    public var availableBytes: UInt64
    public var maxFileBytes: UInt64?
    public var writable: Bool
    public init(canonicalPath: String, identity: FileIdentity, filesystem: String, availableBytes: UInt64, maxFileBytes: UInt64?, writable: Bool) {
        self.canonicalPath=canonicalPath; self.identity=identity; self.filesystem=filesystem; self.availableBytes=availableBytes; self.maxFileBytes=maxFileBytes; self.writable=writable
    }
}
public struct PreflightReport: Codable, Sendable {
    public var configuration: JobConfiguration
    public var sourceIdentity: FileIdentity
    public var destination: DestinationInfo
    public var files: [SourceFile]
    public var packages: [ClipPackage]
    public var archives: [ArchivePlan]
    public var issues: [String]
    public var warnings: [String]
    public var requiredBytes: UInt64
    public var analyzedAt: Date
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    public var canCreate: Bool { issues.isEmpty && !archives.isEmpty && (!archives.contains(where: \.oversized) || configuration.acknowledgedOversized) }
    public init(configuration: JobConfiguration, sourceIdentity: FileIdentity, destination: DestinationInfo, files: [SourceFile], packages: [ClipPackage], archives: [ArchivePlan], issues: [String], warnings: [String], requiredBytes: UInt64, analyzedAt: Date = Date()) {
        self.configuration=configuration; self.sourceIdentity=sourceIdentity; self.destination=destination; self.files=files; self.packages=packages; self.archives=archives; self.issues=issues; self.warnings=warnings; self.requiredBytes=requiredBytes; self.analyzedAt=analyzedAt
    }
}
public enum ArchiveState: String, Codable, Sendable { case queued = "Queued", hashingSource = "Hashing Source", writing = "Writing", verifyingContents = "Verifying Contents", hashingArchive = "Hashing Archive", verified = "Verified", failed = "Failed", interrupted = "Interrupted" }
public struct ArchiveRecord: Codable, Identifiable, Sendable {
    public var id: String { plan.name }
    public var plan: ArchivePlan
    public var state: ArchiveState = .queued
    public var sha256: String?
    public var actualBytes: UInt64?
    public var failure: String?
    public init(plan: ArchivePlan) { self.plan=plan }
}
public enum JobStatus: String, Codable, Sendable { case running, interrupted, failed, completed }
public struct AuditEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var timestamp = Date()
    public var message: String
    public init(_ message: String) { self.message=message }
}
public struct DeliveryStatistics: Codable, Equatable, Sendable {
    public var sourceFileCount: Int
    public var mediaCount: Int
    public var xmlCount: Int
    public var bimCount: Int
    public var unexpectedFileCount: Int
    public var clipPackageCount: Int
    public var totalSourceBytes: UInt64
    public var finalArchiveCount: Int
    public init(preflight: PreflightReport) {
        sourceFileCount=preflight.files.count
        mediaCount=preflight.files.filter { $0.kind == .media }.count
        xmlCount=preflight.files.filter { $0.kind == .xml }.count
        bimCount=preflight.files.filter { $0.kind == .bim }.count
        unexpectedFileCount=preflight.files.filter { $0.kind != .media && $0.kind != .xml && $0.kind != .bim }.count
        clipPackageCount=preflight.packages.count
        totalSourceBytes=preflight.totalBytes
        finalArchiveCount=preflight.archives.count
    }
    private enum CodingKeys: String, CodingKey {
        case sourceFileCount, mediaCount, xmlCount, bimCount, unexpectedFileCount, clipPackageCount, totalSourceBytes, finalArchiveCount
    }
    public init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        sourceFileCount=try values.decode(Int.self,forKey:.sourceFileCount)
        mediaCount=try values.decode(Int.self,forKey:.mediaCount)
        xmlCount=try values.decode(Int.self,forKey:.xmlCount)
        bimCount=try values.decodeIfPresent(Int.self,forKey:.bimCount) ?? 0
        unexpectedFileCount=try values.decode(Int.self,forKey:.unexpectedFileCount)
        clipPackageCount=try values.decode(Int.self,forKey:.clipPackageCount)
        totalSourceBytes=try values.decode(UInt64.self,forKey:.totalSourceBytes)
        finalArchiveCount=try values.decode(Int.self,forKey:.finalArchiveCount)
    }
}
public struct JobRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var application = "Zipper"
    public var applicationVersion = "1.0.2"
    public var schemaVersion = 1
    public var createdAt = Date()
    public var completedAt: Date?
    public var status: JobStatus = .running
    public var preflight: PreflightReport
    public var archives: [ArchiveRecord]
    public var events: [AuditEvent] = []
    public var failure: String?
    public var finalSourceVerified = false
    public var completionWarning: String?
    public var deliveryStatistics: DeliveryStatistics?
    public init(preflight: PreflightReport, id: UUID = UUID()) { self.id=id; self.preflight=preflight; self.archives=preflight.archives.map(ArchiveRecord.init); self.deliveryStatistics=DeliveryStatistics(preflight:preflight) }
}
public struct JobProgress: Sendable {
    public var operation: String
    public var currentArchive: String
    public var currentFile: String
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var verifiedBytes: UInt64
    public var fraction: Double
    public var verifiedArchives: Int
    public var totalArchives: Int
    public var elapsed: TimeInterval
    public var archiveStates: [String: ArchiveState]
    public init(operation: String = "Preparing", currentArchive: String = "", currentFile: String = "", bytesRead: UInt64 = 0, bytesWritten: UInt64 = 0, verifiedBytes: UInt64 = 0, fraction: Double = 0, verifiedArchives: Int = 0, totalArchives: Int = 0, elapsed: TimeInterval = 0, archiveStates: [String: ArchiveState] = [:]) {
        self.operation=operation; self.currentArchive=currentArchive; self.currentFile=currentFile; self.bytesRead=bytesRead; self.bytesWritten=bytesWritten; self.verifiedBytes=verifiedBytes; self.fraction=fraction; self.verifiedArchives=verifiedArchives; self.totalArchives=totalArchives; self.elapsed=elapsed; self.archiveStates=archiveStates
    }
}
public final class CancellationToken: @unchecked Sendable {
    private let lock=NSLock()
    private var stopped=false
    public init() {}
    public func cancel() { lock.lock(); stopped=true; lock.unlock() }
    public func check() throws { lock.lock(); let value=stopped; lock.unlock(); if value { throw HandoffError.cancelled } }
}
public struct VerificationReport: Sendable {
    public var passed: Bool
    public var checkedArchives: Int
    public var checkedFiles: Int
    public var issues: [String]
    public var checkedAt = Date()
    public var deep: Bool
    public var sourcePath: String?
    public var destination: DestinationInfo?
    public init(passed: Bool, checkedArchives: Int, checkedFiles: Int, issues: [String], deep: Bool, sourcePath: String? = nil, destination: DestinationInfo? = nil) { self.passed=passed; self.checkedArchives=checkedArchives; self.checkedFiles=checkedFiles; self.issues=issues; self.deep=deep; self.sourcePath=sourcePath; self.destination=destination }
}
