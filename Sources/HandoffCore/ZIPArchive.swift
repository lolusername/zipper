import Foundation
import CryptoKit
import Darwin
import CArchive

/// A deterministic, streaming ZIP64 STORE encoder and an independent libarchive verifier.
/// Only Destination can create outputs; all original bytes arrive through ReadOnlySource.
public enum ZIPArchive {
    private static let chunkSize = 1_048_576
    private static let flags: UInt16 = 0x0808 // UTF-8 filenames and trailing data descriptor
    private static let footerBytes: UInt64 = 98
    private static let perFileBytes: UInt64 = 148

    public static func predictedSize(files: [SourceFile]) -> UInt64 {
        files.reduce(footerBytes) { result, file in
            let nameSize = UInt64(file.relativePath.utf8.count)
            let (overhead, firstOverflow) = perFileBytes.addingReportingOverflow(nameSize * 2)
            let (entry, secondOverflow) = file.size.addingReportingOverflow(overhead)
            let (sum, thirdOverflow) = result.addingReportingOverflow(entry)
            return firstOverflow || secondOverflow || thirdOverflow ? UInt64.max : sum
        }
    }

    public static func write(plan: ArchivePlan, source: ReadOnlySource, destination: Destination,
                             partialName: String, cancellation: CancellationToken,
                             sourceProgress: (String, UInt64) throws -> Void = { _, _ in },
                             progress: (String, UInt64) throws -> Void) throws -> UInt64 {
        let files = plan.files
        try validateFiles(files)
        let predicted = predictedSize(files: files)
        guard predicted != UInt64.max, plan.predictedBytes == predicted else {
            throw HandoffError.blocked("ZIP size differs from the approved preflight plan.")
        }
        try cancellation.check()
        try destination.validateIdentity()
        let fd = try destination.createExclusive(partialName)
        var closed = false
        defer { if !closed { Darwin.close(fd) } }
        var written: UInt64 = 0
        var entries: [(offset: UInt64, crc: UInt32)] = []
        var bytesSinceCapacityCheck: UInt64 = 0
        func append(_ data: Data, member: String) throws {
            try cancellation.check()
            let (next, overflow) = written.addingReportingOverflow(UInt64(data.count))
            guard !overflow, next <= predicted else {
                throw HandoffError.integrity("Writing \(partialName) exceeded its exact approved ZIP size.")
            }
            if bytesSinceCapacityCheck == 0 || bytesSinceCapacityCheck >= 64 * 1_048_576 {
                try destination.validateIdentity()
                guard try destination.availableBytes() >= UInt64(data.count) + 8 * 1_048_576 else {
                    throw HandoffError.io("Destination capacity is critically low while writing \(partialName). The incomplete archive remains .partial.")
                }
                bytesSinceCapacityCheck = 0
            }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try cancellation.check()
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw ioError("Write failed for \(partialName)") }
                    guard count > 0 else { throw HandoffError.io("Writing \(partialName) made no progress.") }
                    offset += count
                    written += UInt64(count)
                    bytesSinceCapacityCheck += UInt64(count)
                    try progress(member, UInt64(count))
                }
            }
        }
        for file in files {
            try cancellation.check()
            let offset = written
            try append(localHeader(file), member: file.relativePath)
            var digest = SHA256()
            var crc: uLong = 0
            var consumed: UInt64 = 0
            try source.stream(file, cancellation: cancellation) { data in
                guard UInt64(data.count) <= file.size - min(consumed, file.size) else {
                    throw HandoffError.integrity("Source size changed while packaging \(file.relativePath).")
                }
                digest.update(data: data)
                crc = data.withUnsafeBytes { raw in crc32(crc, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)) }
                consumed += UInt64(data.count)
                try sourceProgress(file.relativePath, UInt64(data.count))
                try append(data, member: file.relativePath)
            }
            guard consumed == file.size, hex(digest.finalize()) == file.sha256 else {
                throw HandoffError.integrity("Source SHA-256 changed while packaging \(file.relativePath).")
            }
            let value = UInt32(truncatingIfNeeded: crc)
            try append(descriptor(size: file.size, crc: value), member: file.relativePath)
            entries.append((offset, value))
        }
        let directoryOffset = written
        for (file, entry) in zip(files, entries) {
            try append(centralHeader(file, offset: entry.offset, crc: entry.crc), member: file.relativePath)
        }
        try append(footer(count: UInt64(files.count), directoryOffset: directoryOffset, directorySize: written - directoryOffset), member: "ZIP directory")
        guard written == predicted else { throw HandoffError.integrity("Final ZIP size did not match preflight.") }
        try cancellation.check()
        try destination.validateIdentity()
        guard fsync(fd) == 0 else { throw ioError("Could not flush \(partialName)") }
        if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP && errno != ENOTTY {
            throw ioError("Could not synchronize \(partialName) to storage")
        }
        let closeResult = Darwin.close(fd)
        closed = true
        guard closeResult == 0 else { throw ioError("Could not close \(partialName)") }
        return written
    }

    @discardableResult
    public static func verify(name: String, files: [SourceFile], destination: Destination,
                              cancellation: CancellationToken, progress: (String, UInt64) throws -> Void) throws -> FileIdentity {
        try validateFiles(files)
        try cancellation.check()
        try destination.validateIdentity()
        let fd = try destination.openRead(name)
        defer { Darwin.close(fd) }
        let before = try identity(fd, name: name)
        try validateStructure(fd: fd, actualBytes: UInt64(before.st_size), files: files, cancellation: cancellation)
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw ioError("Could not rewind \(name)") }
        guard let reader = archive_read_new() else { throw HandoffError.io("Could not initialize the independent ZIP reader.") }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_zip_seekable(reader) == ARCHIVE_OK,
              archive_read_open_fd(reader, fd, chunkSize) == ARCHIVE_OK else {
            throw archiveError(reader, context: "Cannot reopen \(name)")
        }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var seen = Set<String>()
        let expected = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        while true {
            try cancellation.check()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry else { throw archiveError(reader, context: "Invalid ZIP header in \(name)") }
            guard let path = archive_entry_pathname_utf8(entry), let member = String(validatingUTF8: path),
                  let file = expected[member], seen.insert(member).inserted,
                  archive_entry_filetype(entry) == UInt32(S_IFREG),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                  archive_entry_size_is_set(entry) != 0, archive_entry_size(entry) >= 0,
                  UInt64(archive_entry_size(entry)) == file.size else {
                throw HandoffError.integrity("ZIP \(name) contains an unexpected, duplicate, unsafe, or incorrectly sized member.")
            }
            var digest = SHA256()
            var count: UInt64 = 0
            while true {
                try cancellation.check()
                let readCount = archive_read_data(reader, &buffer, buffer.count)
                guard readCount >= 0 else { throw archiveError(reader, context: "Cannot read archived member \(member)") }
                if readCount == 0 { break }
                guard UInt64(readCount) <= file.size - min(count, file.size) else { throw HandoffError.integrity("Archived member \(member) exceeds its expected size.") }
                count += UInt64(readCount)
                buffer.withUnsafeBytes { raw in digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<readCount])) }
                try progress(member, UInt64(readCount))
            }
            guard count == file.size, hex(digest.finalize()) == file.sha256 else {
                throw HandoffError.integrity("Archived member SHA-256 or byte count mismatch: \(member).")
            }
        }
        guard seen.count == files.count else { throw HandoffError.integrity("ZIP \(name) is missing expected members.") }
        guard archive_read_close(reader) == ARCHIVE_OK else { throw archiveError(reader, context: "ZIP reader close failed for \(name)") }
        try unchanged(fd, before: before, name: name, destination: destination)
        try destination.validateIdentity()
        return fileIdentity(before)
    }

    public static func hash(name: String, destination: Destination, cancellation: CancellationToken,
                            progress: (UInt64) throws -> Void) throws -> (sha256: String, bytes: UInt64, identity: FileIdentity) {
        try cancellation.check()
        try destination.validateIdentity()
        let fd = try destination.openRead(name)
        defer { Darwin.close(fd) }
        let before = try identity(fd, name: name)
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var bytes: UInt64 = 0
        while true {
            try cancellation.check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ioError("Cannot hash \(name)") }
            if count == 0 { break }
            bytes += UInt64(count)
            buffer.withUnsafeBytes { raw in digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<count])) }
            try progress(UInt64(count))
        }
        guard bytes == UInt64(before.st_size) else { throw HandoffError.integrity("Archive changed size while hashing: \(name).") }
        try unchanged(fd, before: before, name: name, destination: destination)
        try destination.validateIdentity()
        return (hex(digest.finalize()), bytes, fileIdentity(before))
    }

    // Enforce our canonical ZIP64 layout, including every central-directory entry and
    // end record. A streaming reader alone can accept truncated/missing directories.
    private static func validateStructure(fd: Int32, actualBytes: UInt64, files: [SourceFile], cancellation: CancellationToken) throws {
        guard actualBytes == predictedSize(files: files), actualBytes <= UInt64(Int64.max) else {
            throw HandoffError.integrity("Archive is truncated, has trailing bytes, or differs from its predicted ZIP64 size.")
        }
        var entries: [(offset: UInt64, crc: UInt32)] = []
        var offset: UInt64 = 0
        for file in files {
            try cancellation.check()
            let local = localHeader(file)
            guard try readAt(fd, offset: offset, length: local.count) == local else {
                throw HandoffError.integrity("Invalid local ZIP64 header for \(file.relativePath).")
            }
            let descriptorOffset = offset + UInt64(local.count) + file.size
            let stored = try readAt(fd, offset: descriptorOffset, length: 24)
            let crc = uint32(stored, at: 4)
            guard stored == descriptor(size: file.size, crc: crc) else {
                throw HandoffError.integrity("Invalid ZIP64 data descriptor for \(file.relativePath).")
            }
            entries.append((offset, crc))
            offset = descriptorOffset + 24
        }
        let directoryOffset = offset
        for (file, entry) in zip(files, entries) {
            try cancellation.check()
            let central = centralHeader(file, offset: entry.offset, crc: entry.crc)
            guard try readAt(fd, offset: offset, length: central.count) == central else {
                throw HandoffError.integrity("ZIP central-directory mismatch for \(file.relativePath).")
            }
            offset += UInt64(central.count)
        }
        let end = footer(count: UInt64(files.count), directoryOffset: directoryOffset, directorySize: offset - directoryOffset)
        guard try readAt(fd, offset: offset, length: end.count) == end, offset + UInt64(end.count) == actualBytes else {
            throw HandoffError.integrity("ZIP64 end records are missing or inconsistent.")
        }
    }

    private static func validateFiles(_ files: [SourceFile]) throws {
        guard !files.isEmpty else { throw HandoffError.blocked("Empty archives are not allowed.") }
        var names = Set<String>()
        for file in files {
            let name = file.relativePath
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.contains(":"), !name.contains("\0"), !name.contains("\n"), !name.contains("\r"),
                  name.utf8.count <= Int(UInt16.max), names.insert(name).inserted else {
                throw HandoffError.blocked("Unsafe, duplicate, or excessively long ZIP member name: \(name).")
            }
            guard file.size <= UInt64(Int64.max), let hash = file.sha256,
                  hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw HandoffError.integrity("A valid source SHA-256 and size are required before archiving \(name).")
            }
        }
    }

    private static func localHeader(_ file: SourceFile) -> Data {
        var d = Data()
        d.le(UInt32(0x04034b50)); d.le(UInt16(45)); d.le(flags); d.le(UInt16(0)); d.le(UInt16(0)); d.le(UInt16(0x0021))
        d.le(UInt32(0)); d.le(UInt32.max); d.le(UInt32.max)
        d.le(UInt16(clamping: file.relativePath.utf8.count)); d.le(UInt16(20)); d.append(contentsOf: file.relativePath.utf8)
        d.le(UInt16(1)); d.le(UInt16(16)); d.le(file.size); d.le(file.size)
        return d
    }
    private static func descriptor(size: UInt64, crc: UInt32) -> Data {
        var d = Data(); d.le(UInt32(0x08074b50)); d.le(crc); d.le(size); d.le(size); return d
    }
    private static func centralHeader(_ file: SourceFile, offset: UInt64, crc: UInt32) -> Data {
        var d = Data()
        d.le(UInt32(0x02014b50)); d.le(UInt16(0x032d)); d.le(UInt16(45)); d.le(flags)
        d.le(UInt16(0)); d.le(UInt16(0)); d.le(UInt16(0x0021)); d.le(crc); d.le(UInt32.max); d.le(UInt32.max)
        d.le(UInt16(clamping: file.relativePath.utf8.count)); d.le(UInt16(28)); d.le(UInt16(0)); d.le(UInt16(0)); d.le(UInt16(0))
        d.le(UInt32(0o100644) << 16); d.le(UInt32.max); d.append(contentsOf: file.relativePath.utf8)
        d.le(UInt16(1)); d.le(UInt16(24)); d.le(file.size); d.le(file.size); d.le(offset)
        return d
    }
    private static func footer(count: UInt64, directoryOffset: UInt64, directorySize: UInt64) -> Data {
        var d = Data()
        d.le(UInt32(0x06064b50)); d.le(UInt64(44)); d.le(UInt16(0x032d)); d.le(UInt16(45)); d.le(UInt32(0)); d.le(UInt32(0))
        d.le(count); d.le(count); d.le(directorySize); d.le(directoryOffset)
        d.le(UInt32(0x07064b50)); d.le(UInt32(0)); d.le(directoryOffset + directorySize); d.le(UInt32(1))
        d.le(UInt32(0x06054b50)); d.le(UInt16(0)); d.le(UInt16(0)); d.le(UInt16.max); d.le(UInt16.max)
        d.le(UInt32.max); d.le(UInt32.max); d.le(UInt16(0))
        return d
    }
    private static func readAt(_ fd: Int32, offset: UInt64, length: Int) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in
            var count = 0
            while count < length {
                let readCount = pread(fd, raw.baseAddress!.advanced(by: count), length - count, off_t(offset + UInt64(count)))
                if readCount < 0 { if errno == EINTR { continue }; throw ioError("ZIP structure read failed") }
                guard readCount > 0 else { throw HandoffError.integrity("ZIP structure is truncated.") }
                count += readCount
            }
        }
        return data
    }
    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    private static func identity(_ fd: Int32, name: String) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ioError("Cannot inspect \(name)") }
        guard (value.st_mode & S_IFMT) == S_IFREG, value.st_size >= 0 else { throw HandoffError.integrity("Archive is not a regular file: \(name).") }
        return value
    }
    private static func unchanged(_ fd: Int32, before: stat, name: String, destination: Destination) throws {
        let after = try identity(fd, name: name)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw HandoffError.integrity("Archive changed during verification: \(name).")
        }
        let named = try destination.openRead(name)
        defer { Darwin.close(named) }
        guard fileIdentity(try identity(named, name: name)) == fileIdentity(before) else {
            throw HandoffError.integrity("Archive was replaced during verification: \(name).")
        }
    }
    private static func archiveError(_ reader: OpaquePointer, context: String) -> HandoffError {
        let details = archive_error_string(reader).map { String(cString: $0) } ?? "Unknown ZIP reader error"
        return .integrity("\(context): \(details)")
    }
    private static func ioError(_ context: String) -> HandoffError { .io("\(context): \(String(cString: strerror(errno)))") }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
