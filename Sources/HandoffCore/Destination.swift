import Foundation
import Darwin

/// Every output operation is confined to an identity-checked directory descriptor.
public final class Destination: @unchecked Sendable {
    public let info: DestinationInfo
    private let directoryDescriptor: Int32
    private let sources: [ReadOnlySource]

    public init(url: URL, source: ReadOnlySource? = nil, additionalSources: [ReadOnlySource] = []) throws {
        let protectedSources = (source.map { [$0] } ?? []) + additionalSources
        let path = try canonicalDirectory(url)
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileSystemError("Cannot open destination", path) }
        do {
            for source in protectedSources {
                if try source.overlaps(directory: descriptor) {
                    throw HandoffError.blocked("Source and destination overlap. Choose separate directories; neither may contain the other.")
                }
            }
            let identity = fileIdentity(try descriptorStatus(descriptor, context: path))
            var volume = statfs()
            guard fstatfs(descriptor, &volume) == 0 else { throw fileSystemError("Cannot inspect destination filesystem", path) }
            let filesystem = withUnsafePointer(to: &volume.f_fstypename) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            let readOnly = (volume.f_flags & UInt32(MNT_RDONLY)) != 0
            let writable = !readOnly && faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0
            let limit = Self.maximumFileBytes(filesystem: filesystem)
            let free = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
            let inspected = DestinationInfo(canonicalPath: path, identity: identity, filesystem: filesystem,
                                            availableBytes: free.overflow ? UInt64.max : free.partialValue, maxFileBytes: limit, writable: writable)
            // Finish throwing checks before transferring descriptor ownership to self, so a
            // failing initializer cannot close it once here and again from deinit.
            try Self.validateIdentity(descriptor: descriptor, info: inspected, sources: protectedSources)
            self.info = inspected
            self.directoryDescriptor = descriptor
            self.sources = protectedSources
        } catch { Darwin.close(descriptor); throw error }
    }

    deinit { Darwin.close(directoryDescriptor) }

    internal static func maximumFileBytes(filesystem: String) -> UInt64? {
        ["msdos", "msdosfs", "fat", "fat32", "vfat"].contains(filesystem.lowercased()) ? 4_294_967_295 : nil
    }

    public func validateIdentity() throws {
        try Self.validateIdentity(descriptor: directoryDescriptor, info: info, sources: sources)
    }

    private static func validateIdentity(descriptor: Int32, info: DestinationInfo, sources: [ReadOnlySource]) throws {
        let opened = try descriptorStatus(descriptor, context: info.canonicalPath)
        var path = stat()
        guard lstat(info.canonicalPath, &path) == 0 else { throw fileSystemError("Destination is unavailable", info.canonicalPath) }
        guard opened.st_mode & S_IFMT == S_IFDIR, path.st_mode & S_IFMT == S_IFDIR,
              sameObject(fileIdentity(opened), info.identity), sameObject(fileIdentity(path), info.identity) else {
            throw HandoffError.integrity("Destination identity changed. Reconnected drives must be revalidated before continuing.")
        }
        for source in sources {
            if try source.overlaps(directory: descriptor) {
                throw HandoffError.blocked("Destination now overlaps source. Output has stopped.")
            }
        }
    }

    /// Integrity claims require stable source metadata even when no writes are requested.
    /// Repeated calls also detect a formerly read-only non-APFS volume being remounted writable.
    public func validateIntegrityReadSafety() throws {
        try validateIdentity()
        let volume = try filesystemState(directoryDescriptor, role: "destination")
        try FilesystemStabilityPolicy.validateReading(filesystem: volume.name, isReadOnly: volume.readOnly, role: "delivery")
    }

    public func validateWriteSafety() throws {
        try validateIdentity()
        let volume = try filesystemState(directoryDescriptor, role: "destination")
        try FilesystemStabilityPolicy.validateWriting(filesystem: volume.name, isReadOnly: volume.readOnly)
    }

    public func availableBytes() throws -> UInt64 {
        try validateIdentity()
        var volume = statfs()
        guard fstatfs(directoryDescriptor, &volume) == 0 else { throw fileSystemError("Cannot read destination capacity", info.canonicalPath) }
        guard volume.f_flags & UInt32(MNT_RDONLY) == 0 else { throw HandoffError.io("Destination filesystem became read only.") }
        let result = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
        return result.overflow ? UInt64.max : result.partialValue
    }

    public func names() throws -> [String] { try validateIdentity(); return try directoryNames(directoryDescriptor) }

    public func createExclusive(_ name: String) throws -> Int32 {
        try validateWriteSafety()
        try validateLeafName(name)
        let descriptor = openat(directoryDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw fileSystemError("Cannot create exclusive destination output", name) }
        do { try validateIdentity(); try sync(); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }

    public func openRead(_ name: String) throws -> Int32 {
        try validateIdentity()
        try validateLeafName(name)
        let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw fileSystemError("Cannot read destination output", name) }
        do {
            let status = try descriptorStatus(descriptor, context: name)
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
                throw HandoffError.integrity("Destination output is not a private regular file: \(name).")
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    /// Obtain the identity of the actual readable object and confirm the anchored name still
    /// denotes it. Used to retain and revalidate post-promotion evidence before job success.
    public func identityOf(_ name: String) throws -> FileIdentity {
        let descriptor = try openRead(name)
        defer { Darwin.close(descriptor) }
        let opened = fileIdentity(try descriptorStatus(descriptor, context: name))
        let named = try entryStatus(directoryDescriptor, name: name)
        guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
              fileIdentity(named) == opened,
              fileIdentity(try descriptorStatus(descriptor, context: name)) == opened else {
            throw HandoffError.integrity("Destination output changed while checking its identity: \(name).")
        }
        try validateIdentity()
        return opened
    }

    @discardableResult
    public func renameExclusive(from: String, to: String, expectedIdentity: FileIdentity? = nil) throws -> FileIdentity {
        try validateWriteSafety()
        try validateLeafName(from)
        try validateLeafName(to)
        let current = try entryStatus(directoryDescriptor, name: from)
        guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1 else {
            throw HandoffError.integrity("Cannot promote an unsafe destination entry: \(from).")
        }
        if let expectedIdentity, fileIdentity(current) != expectedIdentity {
            throw HandoffError.integrity("Verified destination output was replaced or changed before promotion: \(from).")
        }
        guard renameatx_np(directoryDescriptor, from, directoryDescriptor, to, UInt32(RENAME_EXCL)) == 0 else {
            throw fileSystemError("Cannot promote verified archive without overwriting existing output", to)
        }
        let promoted = try entryStatus(directoryDescriptor, name: to)
        let originalIdentity = expectedIdentity ?? fileIdentity(current)
        let promotedIdentity = fileIdentity(promoted)
        guard promoted.st_mode & S_IFMT == S_IFREG, promoted.st_nlink == 1,
              sameObject(originalIdentity, promotedIdentity), originalIdentity.size == promotedIdentity.size,
              originalIdentity.modifiedSeconds == promotedIdentity.modifiedSeconds,
              originalIdentity.modifiedNanoseconds == promotedIdentity.modifiedNanoseconds else {
            throw HandoffError.integrity("Destination output changed during promotion: \(to). It must not be delivered.")
        }
        try sync()
        return promotedIdentity
    }

    /// Returns the promoted object's identity, tied to the descriptor whose bytes were
    /// written, rather than accepting a subsequently reopened replacement as evidence.
    @discardableResult
    public func writeAtomic(_ data: Data, name: String, replace: Bool) throws -> FileIdentity {
        try validateWriteSafety()
        try validateLeafName(name)
        let temporary = ".\(name).pending"
        try validateLeafName(temporary)
        let descriptor = try createExclusive(temporary)
        let writtenIdentity: FileIdentity
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw fileSystemError("Cannot write destination state", name) }
                    guard written > 0 else { throw HandoffError.io("Destination accepted no data while writing \(name).") }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw fileSystemError("Cannot flush destination state", name) }
            // On macOS F_FULLFSYNC also requests a drive-cache flush. Unsupported filesystems still require fsync above.
            if fcntl(descriptor, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP && errno != ENOTTY {
                throw fileSystemError("Cannot synchronize destination state to storage", name)
            }
            writtenIdentity = fileIdentity(try descriptorStatus(descriptor, context: temporary))
        } catch { Darwin.close(descriptor); throw error }
        guard Darwin.close(descriptor) == 0 else { throw fileSystemError("Cannot close destination state", name) }
        try validateIdentity()
        if replace {
            guard fileIdentity(try entryStatus(directoryDescriptor, name: temporary)) == writtenIdentity else {
                throw HandoffError.integrity("Pending destination state changed before saving: \(temporary).")
            }
            var existing = stat()
            if fstatat(directoryDescriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else {
                    throw HandoffError.integrity("Refusing to replace an unsafe destination entry: \(name).")
                }
            } else if errno != ENOENT { throw fileSystemError("Cannot inspect destination state", name) }
            guard renameat(directoryDescriptor, temporary, directoryDescriptor, name) == 0 else {
                throw fileSystemError("Cannot atomically save destination state", name)
            }
            let published = try entryStatus(directoryDescriptor, name: name)
            let publishedIdentity = fileIdentity(published)
            guard published.st_mode & S_IFMT == S_IFREG, published.st_nlink == 1,
                  sameObject(publishedIdentity, writtenIdentity), publishedIdentity.size == writtenIdentity.size,
                  publishedIdentity.modifiedSeconds == writtenIdentity.modifiedSeconds,
                  publishedIdentity.modifiedNanoseconds == writtenIdentity.modifiedNanoseconds else {
                throw HandoffError.integrity("Destination state changed while saving: \(name).")
            }
            try sync()
            return publishedIdentity
        } else { return try renameExclusive(from: temporary, to: name, expectedIdentity: writtenIdentity) }
    }

    public func sync() throws {
        try validateWriteSafety()
        guard fsync(directoryDescriptor) == 0 else { throw fileSystemError("Cannot synchronize destination directory", info.canonicalPath) }
    }
}
