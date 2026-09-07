import Foundation

public enum Preflight {
    public static let deliveryNames = ["HANDOFF_MANIFEST.txt", "HANDOFF_MANIFEST.json", "SHA256SUMS.txt", "HANDOFF_LOG.txt", ".zipper-job.json", ".zipper-job.lock"]

    /// Analyze uses only read-only filesystem operations. It never creates probe files or job state.
    public static func analyze(_ configuration: JobConfiguration,
                               cancellation: CancellationToken = CancellationToken()) throws -> PreflightReport {
        try cancellation.check()
        let source = try ReadOnlySource(url: URL(fileURLWithPath: configuration.sourcePath))
        let destination = try Destination(url: URL(fileURLWithPath: configuration.destinationPath), source: source)
        let files = try source.scan()
        var issues: [String] = []
        var warnings: [String] = []

        if files.isEmpty { issues.append("Source is empty. Select a flat directory containing media and matching XML sidecars.") }
        if configuration.prefix.isEmpty || configuration.prefix.utf8.count > 100 ||
            configuration.prefix.unicodeScalars.contains(where: { !CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }) {
            issues.append("Output prefix must contain 1–100 ASCII letters, digits, underscores, or hyphens.")
        }

        let ambiguousNames = Dictionary(grouping: files, by: { collisionKey($0.relativePath) })
        for group in ambiguousNames.values.filter({ $0.count > 1 }).sorted(by: { $0[0].relativePath < $1[0].relativePath }) {
            issues.append("Ambiguous filenames differ only by case or Unicode representation: \(group.map(\.relativePath).sorted().joined(separator: ", ")).")
        }

        for file in files {
            try cancellation.check()
            do { try validateLeafName(file.relativePath) }
            catch { issues.append(error.localizedDescription) }
            switch file.kind {
            case .hidden:
                issues.append("Hidden/system file requires operator resolution: \(file.relativePath). No source files are silently omitted.")
            case .directory:
                issues.append("Nested directory is unsupported in v1: \(file.relativePath). Select a flat media/XML directory.")
            case .symlink:
                issues.append("Symbolic link is unsupported in source: \(file.relativePath).")
            case .unexpected:
                issues.append("Unexpected file requires operator resolution: \(file.relativePath). No source files are silently omitted.")
            case .media, .xml:
                do { try source.validate(file) }
                catch { issues.append(error.localizedDescription) }
            }
        }

        var packages: [ClipPackage] = []
        let recognized = files.filter { $0.kind == .media || $0.kind == .xml }
        let groups = Dictionary(grouping: recognized, by: { collisionKey($0.basename) })
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let media = group.filter { $0.kind == .media }
            let xml = group.filter { $0.kind == .xml }
            if media.isEmpty { issues.append("Missing media: \(xml.map(\.relativePath).joined(separator: ", ")) has no matching supported media file.") }
            if xml.isEmpty { issues.append("Missing XML: \(media.map(\.relativePath).joined(separator: ", ")) has no matching XML sidecar.") }
            if media.count > 1 || xml.count > 1 {
                issues.append("Duplicate/ambiguous basename: \(group.map(\.relativePath).sorted().joined(separator: ", ")). Each package requires exactly one media and one XML file.")
            }
            if media.count == 1, xml.count == 1 {
                guard Array(media[0].basename.utf8) == Array(xml[0].basename.utf8), !media[0].basename.isEmpty else {
                    issues.append("Media/XML basenames must match exactly, including case and Unicode representation: \(media[0].relativePath), \(xml[0].relativePath).")
                    continue
                }
                packages.append(ClipPackage(basename: media[0].basename, media: media[0], xml: xml[0]))
            }
        }

        packages.sort { $0.basename.utf8.lexicographicallyPrecedes($1.basename.utf8) }
        let archives = plan(packages, configuration: configuration, issues: &issues)
        let existing = Set(try destination.names().map(collisionKey))
        let outputs = archives.flatMap { [$0.name, ".\($0.name).partial"] } + deliveryNames
        let candidates = outputs + deliveryNames.map { ".\($0).pending" }
        for name in candidates where existing.contains(collisionKey(name)) {
            issues.append("Output collision: \(name) already exists. Choose another destination/prefix, or resume the existing job. Existing delivery files will not be overwritten.")
        }
        if !destination.info.writable { issues.append("Destination is not writable. Choose a writable destination volume.") }
        if source.identity.device == destination.info.identity.device {
            warnings.append("Source and destination are on the same filesystem/device. A device failure could affect both copies; this handoff is not a separate-device backup.")
        } else {
            warnings.append("Separate filesystem identities do not establish separate physical drives. Confirm that source and destination use independent devices when a backup is required.")
        }
        if let limit = destination.info.maxFileBytes {
            for archive in archives where archive.predictedBytes > limit {
                issues.append("\(destination.info.filesystem.uppercased()) cannot hold \(archive.name) (\(formatBytes(archive.predictedBytes))). Its file limit is \(formatBytes(limit)); choose APFS or exFAT storage.")
            }
        } else if !["apfs", "hfs", "exfat", "nfs", "smbfs", "webdav", "ufs"].contains(destination.info.filesystem.lowercased()) {
            issues.append("Destination filesystem \(destination.info.filesystem) has an unverified maximum file size. Choose a supported APFS, HFS+, exFAT, SMB, or NFS destination.")
        }
        if ["nfs", "smbfs", "webdav"].contains(destination.info.filesystem.lowercased()) {
            warnings.append("Network destination durability and maximum file size depend on the server. A flush or exclusive rename failure stops the job safely.")
        }
        let archiveBytes = archives.reduce(UInt64(0)) { saturatingAdd($0, $1.predictedBytes) }
        // The partial is promoted in place, so no second archive-sized temporary copy is needed.
        // Reserve room for repeated manifest/state snapshots plus filesystem allocation and drive headroom.
        let reportReserve = max(UInt64(8 * 1024 * 1024), saturatingMultiply(UInt64(files.count), 16 * 1024))
        let base = saturatingAdd(archiveBytes, reportReserve)
        let margin = max(UInt64(64 * 1024 * 1024), base / 20 + (base % 20 == 0 ? 0 : 1))
        let required = saturatingAdd(base, margin)
        if required > destination.info.availableBytes {
            issues.append("Insufficient destination capacity: \(formatBytes(required)) required including ZIP overhead, reports, temporary state, and safety margin; \(formatBytes(destination.info.availableBytes)) available.")
        }
        for archive in archives where archive.oversized {
            warnings.append("Clip \(archive.packages[0].basename) requires a \(formatBytes(archive.predictedBytes)) archive and exceeds the selected maximum. Explicit acknowledgment is required; the clip will remain indivisible.")
        }
        try cancellation.check()
        // Detect any mutation during analysis, including directory entry additions/removals.
        let rescan = try source.scan()
        guard rescan == files else { throw HandoffError.integrity("Source changed during preflight. Start a new analysis.") }
        try destination.validateIdentity()
        return PreflightReport(configuration: configuration, sourceIdentity: source.identity, destination: destination.info,
                               files: files, packages: packages, archives: archives, issues: issues, warnings: warnings,
                               requiredBytes: required)
    }

    private static func plan(_ packages: [ClipPackage], configuration: JobConfiguration,
                             issues: inout [String]) -> [ArchivePlan] {
        guard !packages.isEmpty else { return [] }
        let descending = packages.sorted {
            if $0.totalSize != $1.totalSize { return $0.totalSize > $1.totalSize }
            return $0.basename.utf8.lexicographicallyPrecedes($1.basename.utf8)
        }
        var bins: [[ClipPackage]] = []
        switch configuration.mode {
        case .maximumBytes(let maximum):
            guard maximum > 0 else { issues.append("Maximum ZIP size must be greater than zero."); return [] }
            // First-fit decreasing, using full exact ZIP64 overhead for every candidate bin.
            for package in descending {
                let alone = ZIPArchive.predictedSize(files: package.files)
                if alone > maximum { bins.append([package]); continue }
                if let index = bins.indices.first(where: { ZIPArchive.predictedSize(files: (bins[$0] + [package]).flatMap(\.files)) <= maximum }) {
                    bins[index].append(package)
                } else { bins.append([package]) }
            }
        case .archiveCount(let count):
            guard count > 0 else { issues.append("Number of archives must be at least one."); return [] }
            guard count <= packages.count else {
                issues.append("Requested \(count) archives for \(packages.count) ClipPackages. Empty ZIPs are prohibited; reduce the archive count.")
                return []
            }
            bins = Array(repeating: [], count: count)
            var sizes = Array(repeating: UInt64(0), count: count)
            for (offset, package) in descending.enumerated() {
                // Seed each bin to ensure exactly N nonempty independent archives, then use LPT.
                let index = offset < count ? offset : sizes.indices.min(by: { sizes[$0] == sizes[$1] ? $0 < $1 : sizes[$0] < sizes[$1] })!
                bins[index].append(package)
                sizes[index] = ZIPArchive.predictedSize(files: bins[index].flatMap(\.files))
            }
        }
        return bins.enumerated().map { index, bin in
            let members = bin.sorted { $0.basename.utf8.lexicographicallyPrecedes($1.basename.utf8) }
            let bytes = ZIPArchive.predictedSize(files: members.flatMap(\.files))
            let oversized: Bool
            if case .maximumBytes(let maximum) = configuration.mode { oversized = bytes > maximum } else { oversized = false }
            return ArchivePlan(name: String(format: "%@_%03d.zip", configuration.prefix, index + 1),
                               packages: members, predictedBytes: bytes, oversized: oversized)
        }
    }
}

internal func collisionKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX")) }
internal func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 { let n = a.addingReportingOverflow(b); return n.overflow ? .max : n.partialValue }
internal func saturatingMultiply(_ a: UInt64, _ b: UInt64) -> UInt64 { let n = a.multipliedReportingOverflow(by: b); return n.overflow ? .max : n.partialValue }
internal func formatBytes(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal) }
