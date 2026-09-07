import Foundation
import CryptoKit
import Darwin

/// The sole production gateway to camera originals. No source descriptor is ever writable.
public final class ReadOnlySource: @unchecked Sendable {
    public let canonicalPath: String
    public let identity: FileIdentity
    private let directoryDescriptor: Int32

    public init(url: URL) throws {
        let path = try canonicalDirectory(url)
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileSystemError("Cannot open SOURCE — READ ONLY", path) }
        do {
            // Keep descriptor ownership local through every throwing check. Once all stored
            // properties are initialized, Swift runs deinit when init throws.
            let status = try descriptorStatus(descriptor, context: path)
            let openedIdentity = fileIdentity(status)
            try Self.validateRoot(descriptor: descriptor, canonicalPath: path, identity: openedIdentity)
            self.canonicalPath = path
            self.identity = openedIdentity
            self.directoryDescriptor = descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    deinit { Darwin.close(directoryDescriptor) }

    public func scan() throws -> [SourceFile] {
        try requireStableSourceFilesystem(directoryDescriptor)
        try validateRoot()
        let names = try directoryNames(directoryDescriptor)
        let result = try names.map { name -> SourceFile in
            let status = try entryStatus(directoryDescriptor, name: name)
            let type = status.st_mode & S_IFMT
            let kind: SourceKind
            if type == S_IFLNK { kind = .symlink }
            else if type == S_IFDIR { kind = .directory }
            else if name.hasPrefix(".") { kind = .hidden }
            else if type != S_IFREG { kind = .unexpected }
            else if (name as NSString).pathExtension.lowercased() == "xml" { kind = .xml }
            else if (name as NSString).pathExtension.lowercased() == "bim" { kind = .bim }
            else if SupportedMedia.extensions.contains((name as NSString).pathExtension.lowercased()) { kind = .media }
            else { kind = .unexpected }
            return SourceFile(relativePath: name, basename: (name as NSString).deletingPathExtension,
                              kind: kind, identity: fileIdentity(status))
        }
        try validateRoot()
        return result.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    public func validate(_ file: SourceFile) throws {
        try requireStableSourceFilesystem(directoryDescriptor)
        try validateRoot()
        try validateLeafName(file.relativePath)
        let status = try entryStatus(directoryDescriptor, name: file.relativePath)
        guard status.st_mode & S_IFMT == S_IFREG, fileIdentity(status) == file.identity else {
            throw HandoffError.integrity("Source changed or is no longer a regular file: \(file.relativePath). Start a new analysis.")
        }
        // Opening here checks actual read access without consuming or changing source content.
        let descriptor = try openSource(file)
        Darwin.close(descriptor)
    }

    public func stream(_ file: SourceFile, cancellation: CancellationToken,
                       consume: (Data) throws -> Void) throws {
        try cancellation.check()
        try requireStableSourceFilesystem(directoryDescriptor)
        try validateRoot()
        let descriptor = try openSource(file)
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        var count: UInt64 = 0
        while true {
            try cancellation.check()
            let amount = Darwin.read(descriptor, &buffer, buffer.count)
            if amount < 0 {
                if errno == EINTR { continue }
                throw fileSystemError("Cannot read source file", file.relativePath)
            }
            if amount == 0 { break }
            count += UInt64(amount)
            guard count <= file.size else { throw HandoffError.integrity("Source grew while reading: \(file.relativePath).") }
            try consume(Data(buffer[0..<amount]))
        }
        try cancellation.check()
        guard count == file.size,
              fileIdentity(try descriptorStatus(descriptor, context: file.relativePath)) == file.identity else {
            throw HandoffError.integrity("Source changed while reading: \(file.relativePath).")
        }
        try validate(file)
    }

    public func hash(_ file: SourceFile, cancellation: CancellationToken,
                     progress: (UInt64) -> Void) throws -> String {
        var hasher = SHA256()
        try stream(file, cancellation: cancellation) { bytes in
            hasher.update(data: bytes)
            progress(UInt64(bytes.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func validateSnapshot(_ files: [SourceFile]) throws {
        let current = try scan()
        let expected = files.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        guard current.count == expected.count,
              zip(current, expected).allSatisfy({ a, b in
                  a.relativePath == b.relativePath && a.kind == b.kind && a.identity == b.identity
              }) else {
            throw HandoffError.integrity("The source directory changed after analysis. Start a new analysis; existing verified outputs are preserved.")
        }
        for file in files { try validate(file) }
    }

    internal func validateRoot() throws {
        try Self.validateRoot(descriptor: directoryDescriptor, canonicalPath: canonicalPath, identity: identity)
    }

    private static func validateRoot(descriptor: Int32, canonicalPath: String, identity: FileIdentity) throws {
        let opened = try descriptorStatus(descriptor, context: canonicalPath)
        var resolved = stat()
        guard lstat(canonicalPath, &resolved) == 0 else { throw fileSystemError("Source is unavailable", canonicalPath) }
        guard opened.st_mode & S_IFMT == S_IFDIR, resolved.st_mode & S_IFMT == S_IFDIR,
              fileIdentity(opened) == identity, fileIdentity(resolved) == identity else {
            throw HandoffError.integrity("Source directory identity or contents changed. Reconnect the original source and analyze again.")
        }
    }

    internal func overlaps(directory: Int32) throws -> Bool {
        // Destination state can still be persisted after source content changes. Root identity
        // and ancestry remain mandatory here; detailed source stability belongs to read methods.
        let opened = try descriptorStatus(directoryDescriptor, context: canonicalPath)
        var path = stat()
        guard lstat(canonicalPath, &path) == 0 else { throw fileSystemError("Source is unavailable", canonicalPath) }
        guard opened.st_mode & S_IFMT == S_IFDIR, path.st_mode & S_IFMT == S_IFDIR,
              sameObject(fileIdentity(opened), identity), sameObject(fileIdentity(path), identity) else {
            throw HandoffError.integrity("Source directory identity changed.")
        }
        let destinationIdentity = fileIdentity(try descriptorStatus(directory, context: "destination"))
        if sameObject(identity, destinationIdentity) { return true }

        // Ask the kernel for paths of the already-open objects. NOFIRMLINK also resolves
        // /Users versus /System/Volumes/Data/Users representations of the same APFS tree.
        // Do not walk to /: opening unselected parent directories can trigger macOS privacy
        // authorization and strand an otherwise authorized NSOpenPanel selection in openat.
        let sourceComponents = try descriptorPath(directoryDescriptor).split(separator: "/").map { collisionKey(String($0)) }
        let destinationComponents = try descriptorPath(directory).split(separator: "/").map { collisionKey(String($0)) }
        if destinationComponents.count > sourceComponents.count,
           destinationComponents.starts(with: sourceComponents) {
            return try directoryHasAncestor(directory, identity: identity,
                                            maximumParentSteps: destinationComponents.count - sourceComponents.count)
        }
        if sourceComponents.count > destinationComponents.count,
           sourceComponents.starts(with: destinationComponents) {
            return try directoryHasAncestor(directoryDescriptor, identity: destinationIdentity,
                                            maximumParentSteps: sourceComponents.count - destinationComponents.count)
        }
        return false
    }

    private func openSource(_ file: SourceFile) throws -> Int32 {
        try validateLeafName(file.relativePath)
        guard file.kind == .media || file.kind == .xml || file.kind == .bim else {
            throw HandoffError.blocked("Only validated media, XML, and BIM sidecars may be consumed: \(file.relativePath).")
        }
        // O_NONBLOCK prevents a malicious replacement with a FIFO from hanging the process.
        let descriptor = openat(directoryDescriptor, file.relativePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw fileSystemError("Source file is unavailable or unreadable", file.relativePath) }
        do {
            let status = try descriptorStatus(descriptor, context: file.relativePath)
            guard status.st_mode & S_IFMT == S_IFREG, fileIdentity(status) == file.identity else {
                throw HandoffError.integrity("Source file identity or metadata changed: \(file.relativePath).")
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
}

public enum SupportedMedia {
    /// Flat file camera originals supported by v1. Folder-based camera formats are blocked.
    public static let extensions: Set<String> = ["mov", "mxf", "mp4", "r3d", "braw", "ari", "arx", "crm", "cine", "mts", "m2ts", "avi", "dng"]
}

/// APFS provides change metadata used by the final stability guards. FAT/exFAT/HFS+
/// cannot reliably distinguish same-size rewrites with preserved modification times.
/// A read-only descriptor alone cannot stop another process from changing those files.
internal enum SourceFilesystemPolicy {
    static func validate(filesystem: String, isReadOnly: Bool) throws {
        try FilesystemStabilityPolicy.validateReading(filesystem: filesystem, isReadOnly: isReadOnly, role: "source")
    }
}

/// Integrity readers retain identity/metadata evidence across multiple files. Filesystems
/// whose timestamps cannot represent intervening rewrites require a read-only mount.
internal enum FilesystemStabilityPolicy {
    static func validateReading(filesystem: String, isReadOnly: Bool, role: String) throws {
        let kind = filesystem.lowercased()
        if kind == "apfs" { return }
        if ["hfs", "msdos", "msdosfs", "fat", "fat32", "vfat", "exfat"].contains(kind) {
            guard isReadOnly else {
                throw HandoffError.blocked("The \(filesystem.uppercased()) \(role) must be mounted read-only before integrity analysis or verification. Its timestamps cannot reliably reveal same-size changes made by another process. Mount this volume read-only in macOS, then choose it again. Changing file permissions with chmod is not sufficient.")
            }
            return
        }
        if ["nfs", "smbfs", "webdav", "afpfs"].contains(kind) {
            throw HandoffError.blocked("Network \(role) filesystem \(filesystem.uppercased()) is not supported for verified handoffs: a client read-only mount cannot prevent remote changes. Select local APFS or a read-only mounted local FAT, exFAT, or HFS+ volume.")
        }
        throw HandoffError.blocked("The \(role) filesystem \(filesystem) has not been qualified for change detection. Select local APFS, or a read-only mounted local FAT, exFAT, or HFS+ volume.")
    }

    static func validateWriting(filesystem: String, isReadOnly: Bool) throws {
        guard filesystem.lowercased() == "apfs", !isReadOnly else {
            throw HandoffError.blocked("Creating a verified handoff requires a writable local APFS destination. \(filesystem.uppercased()) cannot provide the required writable-output stability guarantee. Choose a writable APFS destination; existing deliveries on local FAT, exFAT, or HFS+ can be verified when mounted read-only.")
        }
    }
}

private func requireStableSourceFilesystem(_ descriptor: Int32) throws {
    let volume = try filesystemState(descriptor, role: "source")
    try SourceFilesystemPolicy.validate(filesystem: volume.name, isReadOnly: volume.readOnly)
}

internal func filesystemState(_ descriptor: Int32, role: String) throws -> (name: String, readOnly: Bool) {
    var volume = statfs()
    guard fstatfs(descriptor, &volume) == 0 else { throw fileSystemError("Cannot inspect \(role) filesystem stability", "\(role) volume") }
    let filesystem = withUnsafePointer(to: &volume.f_fstypename) { tuple in
        tuple.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
    }
    return (filesystem, volume.f_flags & UInt32(MNT_RDONLY) != 0)
}

internal func fileIdentity(_ status: stat) -> FileIdentity {
    FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino),
                 size: UInt64(max(0, status.st_size)), modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                 modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec), changedSeconds: Int64(status.st_ctimespec.tv_sec),
                 changedNanoseconds: Int64(status.st_ctimespec.tv_nsec))
}

internal func sameObject(_ a: FileIdentity, _ b: FileIdentity) -> Bool { a.device == b.device && a.inode == b.inode }

internal func descriptorStatus(_ descriptor: Int32, context: String) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else { throw fileSystemError("Cannot inspect open directory or file", context) }
    return result
}

internal func entryStatus(_ directory: Int32, name: String) throws -> stat {
    var result = stat()
    guard fstatat(directory, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else { throw fileSystemError("File disappeared or cannot be inspected", name) }
    return result
}

internal func fileSystemError(_ operation: String, _ context: String) -> HandoffError {
    let reason = String(cString: strerror(errno))
    return .io("\(operation): \(context). \(reason).")
}

internal func canonicalDirectory(_ url: URL) throws -> String {
    guard url.isFileURL else { throw HandoffError.blocked("Select a local filesystem directory.") }
    var resolved = url.standardizedFileURL
    if (try? resolved.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true {
        resolved = try URL(resolvingAliasFileAt: resolved, options: [.withoutUI, .withoutMounting])
    }
    guard let real = realpath(resolved.path, nil) else { throw fileSystemError("Directory is unavailable", resolved.path) }
    defer { free(real) }
    return String(cString: real)
}

internal func validateLeafName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"),
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          name.utf8.count <= 255 else { throw HandoffError.blocked("Unsafe or unsupported filename: \(name.debugDescription).") }
}

internal func directoryNames(_ descriptor: Int32) throws -> [String] {
    let enumeration = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard enumeration >= 0 else { throw fileSystemError("Cannot enumerate directory", "openat") }
    guard let directory = fdopendir(enumeration) else {
        Darwin.close(enumeration)
        throw fileSystemError("Cannot enumerate directory", "fdopendir")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno != 0 { throw fileSystemError("Directory enumeration failed", "readdir") }
            break
        }
        let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
        }
        guard let name else { throw HandoffError.blocked("A filename is not valid Unicode. Resolve the source filename before continuing.") }
        if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
}

internal func descriptorPath(_ descriptor: Int32) throws -> String {
    var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH_NOFIRMLINK, &bytes) == 0 else {
        throw fileSystemError("Cannot establish the canonical path of an open directory", "F_GETPATH_NOFIRMLINK")
    }
    guard let path = String(validatingUTF8: bytes), path.hasPrefix("/") else {
        throw HandoffError.blocked("An open directory has an unsupported canonical path.")
    }
    return path
}

internal func directoryHasAncestor(_ descriptor: Int32, identity: FileIdentity, maximumParentSteps: Int) throws -> Bool {
    guard maximumParentSteps >= 0, maximumParentSteps <= 1024 else {
        throw HandoffError.blocked("Directory ancestry exceeds the supported safety limit.")
    }
    var current = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { throw fileSystemError("Cannot establish directory ancestry", "directory") }
    defer { Darwin.close(current) }
    for step in 0...maximumParentSteps {
        let here = fileIdentity(try descriptorStatus(current, context: "directory ancestry"))
        if sameObject(here, identity) { return true }
        // Never open outside the selected candidate ancestor, even when case-insensitive
        // component matching found a false candidate on a case-sensitive filesystem.
        if step == maximumParentSteps { return false }
        let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw fileSystemError("Cannot establish directory ancestry", "parent") }
        let parentIdentity: FileIdentity
        do { parentIdentity = fileIdentity(try descriptorStatus(parent, context: "directory ancestry")) }
        catch { Darwin.close(parent); throw error }
        if sameObject(here, parentIdentity) { Darwin.close(parent); return false }
        Darwin.close(current)
        current = parent
    }
    return false
}
