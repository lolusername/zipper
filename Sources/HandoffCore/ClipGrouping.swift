import Foundation

/// The same file-family rules serve preflight and persisted-manifest validation.
/// Source basenames and archive names remain the original, byte-exact filenames.
public enum ClipGrouping {
    /// Recognized media require one XML: an identical basename, or BASEM01.XML for
    /// BASE.MXF. MXF packages also include BASER01.BIM whenever it is present.
    /// Unknown file kinds are inspected and blocked separately by preflight.
    public static func group(_ files: [SourceFile]) -> (packages: [ClipPackage], issues: [String]) {
        let media = files.filter { $0.kind == .media }.sorted(by: pathOrder)
        let xml = files.filter { $0.kind == .xml }.sorted(by: pathOrder)
        let bim = files.filter { $0.kind == .bim }.sorted(by: pathOrder)
        let xmlByStem = Dictionary(grouping: xml.indices, by: { collisionKey(xml[$0].basename) })
        let bimByStem = Dictionary(grouping: bim.indices, by: { collisionKey(bim[$0].basename) })
        let mediaByStem = Dictionary(grouping: media.indices, by: { collisionKey(media[$0].basename) })
        var xmlCandidates = Array(repeating: [Int](), count: media.count)
        var bimCandidates = Array(repeating: [Int](), count: media.count)
        var xmlOwners = Array(repeating: [Int](), count: xml.count)
        var bimOwners = Array(repeating: [Int](), count: bim.count)
        var invalid = Set<Int>()
        var issues: [String] = []

        for key in mediaByStem.keys.sorted() {
            let owners = mediaByStem[key]!
            if owners.count > 1 {
                invalid.formUnion(owners)
                issues.append("Duplicate/ambiguous basename: \(owners.map { media[$0].relativePath }.joined(separator: ", ")). Each package requires exactly one media and one XML file.")
            }
        }

        // Build the complete candidate graph before choosing anything. An exact
        // XML match must not steal a sidecar also claimed by another MXF family.
        for index in media.indices {
            let file = media[index]
            xmlCandidates[index] = xmlByStem[collisionKey(file.basename)] ?? []
            if isMXF(file) {
                xmlCandidates[index] += xmlByStem[collisionKey(file.basename + "M01")] ?? []
                bimCandidates[index] = bimByStem[collisionKey(file.basename + "R01")] ?? []
            }
            for candidate in xmlCandidates[index] { xmlOwners[candidate].append(index) }
            for candidate in bimCandidates[index] { bimOwners[candidate].append(index) }
        }

        for index in xml.indices {
            if xmlOwners[index].isEmpty {
                issues.append("Missing media: \(xml[index].relativePath) has no matching supported media file.")
            } else if xmlOwners[index].count > 1 {
                invalid.formUnion(xmlOwners[index])
                issues.append("Duplicate/ambiguous XML sidecar: \(xml[index].relativePath) is claimed by \(xmlOwners[index].map { media[$0].relativePath }.joined(separator: ", ")). Each sidecar must belong to exactly one clip.")
            }
        }
        for index in bim.indices {
            if bimOwners[index].isEmpty {
                issues.append("Missing media: BIM sidecar \(bim[index].relativePath) has no matching BASE.MXF for the BASER01.BIM naming pattern. No source files are silently omitted.")
            } else if bimOwners[index].count > 1 {
                invalid.formUnion(bimOwners[index])
                issues.append("Duplicate/ambiguous BIM sidecar: \(bim[index].relativePath) is claimed by multiple media files. Each sidecar must belong to exactly one clip.")
            }
        }

        var packages: [ClipPackage] = []
        for index in media.indices {
            let file = media[index]
            let metadata = xmlCandidates[index].map { xml[$0] }
            let auxiliary = bimCandidates[index].map { bim[$0] }
            if metadata.isEmpty {
                issues.append("Missing XML: \(file.relativePath) has no matching XML sidecar.")
                invalid.insert(index)
            } else if metadata.count > 1 {
                issues.append("Duplicate/ambiguous XML sidecars for \(file.relativePath): \(metadata.map(\.relativePath).joined(separator: ", ")). Each package requires exactly one matching XML file.")
                invalid.insert(index)
            }
            if auxiliary.count > 1 {
                issues.append("Duplicate/ambiguous BIM sidecars for \(file.relativePath): \(auxiliary.map(\.relativePath).joined(separator: ", ")). Each MXF package permits at most one R01.BIM sidecar.")
                invalid.insert(index)
            }
            if metadata.contains(where: { !xmlMatches($0, media: file) }) ||
                auxiliary.contains(where: { !bimMatches($0, media: file) }) {
                issues.append("Media/sidecar basenames must match exactly, including case and Unicode representation, before the optional M01/R01 suffix: \(([file] + metadata + auxiliary).map(\.relativePath).joined(separator: ", ")).")
                invalid.insert(index)
            }
            guard !invalid.contains(index), let sidecar = metadata.first else { continue }
            let package = ClipPackage(basename: file.basename, media: file, xml: sidecar, auxiliaryFiles: auxiliary)
            guard isValid(package) else {
                issues.append("Invalid clip file metadata or filename: \(file.relativePath).")
                continue
            }
            packages.append(package)
        }
        packages.sort { $0.basename.utf8.lexicographicallyPrecedes($1.basename.utf8) }
        return (packages, issues)
    }

    /// Checks one complete package's structure. Call group over the whole source
    /// set as well when validating that sidecars are neither shared nor omitted.
    public static func isValid(_ package: ClipPackage) -> Bool {
        guard !package.basename.isEmpty, exact(package.basename, package.media.basename),
              package.media.kind == .media, package.xml.kind == .xml,
              package.auxiliaryFiles.count <= 1,
              package.files.allSatisfy(validFileMetadata),
              Set(package.files.map { collisionKey($0.relativePath) }).count == package.files.count,
              xmlMatches(package.xml, media: package.media),
              package.auxiliaryFiles.allSatisfy({ bimMatches($0, media: package.media) }) else { return false }
        return true
    }

    private static func validFileMetadata(_ file: SourceFile) -> Bool {
        guard (try? validateLeafName(file.relativePath)) != nil,
              !file.basename.isEmpty,
              exact(file.basename, (file.relativePath as NSString).deletingPathExtension) else { return false }
        let ext = (file.relativePath as NSString).pathExtension.lowercased()
        switch file.kind {
        case .media: return SupportedMedia.extensions.contains(ext)
        case .xml: return ext == "xml"
        case .bim: return ext == "bim"
        default: return false
        }
    }

    private static func xmlMatches(_ sidecar: SourceFile, media: SourceFile) -> Bool {
        sidecar.kind == .xml && (exact(sidecar.basename, media.basename) ||
            (isMXF(media) && suffixed(sidecar.basename, prefix: media.basename, suffix: "M01")))
    }

    private static func bimMatches(_ sidecar: SourceFile, media: SourceFile) -> Bool {
        sidecar.kind == .bim && isMXF(media) && suffixed(sidecar.basename, prefix: media.basename, suffix: "R01")
    }

    private static func isMXF(_ file: SourceFile) -> Bool {
        file.kind == .media && (file.relativePath as NSString).pathExtension.lowercased() == "mxf"
    }

    private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    private static func suffixed(_ name: String, prefix: String, suffix: String) -> Bool {
        let count = suffix.utf8.count
        return name.utf8.count == prefix.utf8.count + count &&
            name.utf8.dropLast(count).elementsEqual(prefix.utf8) &&
            String(decoding: name.utf8.suffix(count), as: UTF8.self).lowercased() == suffix.lowercased()
    }

    private static func pathOrder(_ a: SourceFile, _ b: SourceFile) -> Bool {
        a.relativePath.utf8.lexicographicallyPrecedes(b.relativePath.utf8)
    }
}
