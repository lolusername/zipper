import SwiftUI
import HandoffCore

struct PreflightPanel: View {
    let report: PreflightReport
    @Binding var acknowledgedOversized: Bool
    let job: JobRecord?
    let progress: JobProgress?
    let locked: Bool
    @State private var inventoryExpanded = false
    @State private var inventoryFilter = "All files"
    private var mediaCount: Int { report.files.filter { $0.kind == .media }.count }
    private var xmlCount: Int { report.files.filter { $0.kind == .xml }.count }
    private var unexpected: [SourceFile] { report.files.filter { $0.kind != .media && $0.kind != .xml } }
    private var unmatched: [SourceFile] {
        let matched = Set(report.packages.flatMap(\.files).map(\.relativePath))
        return report.files.filter { ($0.kind == .media || $0.kind == .xml) && !matched.contains($0.relativePath) }
    }
    private var displayedFiles: [SourceFile] {
        switch inventoryFilter {
        case "Unmatched": return unmatched
        case "Unexpected": return unexpected
        default: return report.files
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(title: job == nil ? "PREFLIGHT / INSPECT BEFORE CREATION" : "HANDOFF PLAN")
                    Text(job == nil ? "Your archive plan" : "Archive inventory").font(.system(size: 25, weight: .medium)).tracking(-0.4)
                }
                Spacer()
                if job == nil {
                    StatusTag(title: report.issues.isEmpty ? (report.archives.contains(where: \.oversized) && !acknowledgedOversized ? "Review required" : "Preflight passed") : "\(report.issues.count) blocking \(report.issues.count == 1 ? "issue" : "issues")", color: report.issues.isEmpty ? (report.archives.contains(where: \.oversized) && !acknowledgedOversized ? Studio.amber : Studio.teal) : Studio.red, icon: report.issues.isEmpty ? "checkmark" : "exclamationmark")
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 20) {
                    Metric(label: "SOURCE", value: Studio.bytes(report.totalBytes), detail: "\(mediaCount) media · \(xmlCount) XML")
                    Rectangle().fill(Studio.line).frame(width: 1, height: 62)
                    Metric(label: "CLIP PACKAGES", value: "\(report.packages.count)", detail: "\(report.files.count) source entries")
                    Rectangle().fill(Studio.line).frame(width: 1, height: 62)
                    Metric(label: "PLANNED ARCHIVES", value: "\(report.archives.count)", detail: "Largest \(Studio.bytes(report.archives.map(\.predictedBytes).max() ?? 0))")
                }
                HStack(spacing: 16) {
                    Text("MEDIA \(Studio.bytes(report.files.filter { $0.kind == .media }.reduce(0) { $0 + $1.size }))")
                    Text("XML \(Studio.bytes(report.files.filter { $0.kind == .xml }.reduce(0) { $0 + $1.size }))")
                    Spacer()
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted)
            }.padding(18).background(Studio.surface).clipShape(RoundedRectangle(cornerRadius: 6))

            if !report.issues.isEmpty {
                VStack(spacing: 9) {
                    ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                        Notice(title: "BLOCKED", text: issue, color: Studio.red)
                    }
                    if job == nil { Text("No destination data has been written.").font(Studio.mono).foregroundStyle(Studio.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3) }
                }
            }
            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                Notice(title: "OPERATIONAL WARNING", text: warning)
            }
            if report.archives.contains(where: \.oversized) && job == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(title: "INDIVISIBLE CLIP EXCEEDS MAXIMUM", color: Studio.amber)
                    ForEach(report.archives.filter(\.oversized)) { archive in
                        Text("\(archive.packages.map(\.basename).joined(separator: ", ")) → \(archive.name) · \(Studio.bytes(archive.predictedBytes))")
                            .font(Studio.mono).foregroundStyle(Studio.text).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(isOn: $acknowledgedOversized) {
                        Text("I acknowledge these archives exceed my selected maximum. Keep each clip package intact.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }.toggleStyle(.checkbox).disabled(locked)
                }.padding(15).background(Studio.amber.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 5))
            }

            StudioPanel(title: "DESTINATION & CAPACITY", accessory: report.destination.filesystem.uppercased()) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 20) {
                        Metric(label: "AVAILABLE", value: Studio.bytes(report.destination.availableBytes), tint: report.destination.availableBytes >= report.requiredBytes ? Studio.text : Studio.red)
                        Metric(label: "REQUIRED WITH RESERVE", value: Studio.bytes(report.requiredBytes))
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(title: "ACCESS")
                            StatusTag(title: report.destination.writable ? "Writable" : "Not writable", color: report.destination.writable ? Studio.teal : Studio.red, icon: report.destination.writable ? "checkmark" : "exclamationmark")
                            Text(report.configuration.mode.description).font(.system(size: 11)).foregroundStyle(Studio.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    FineProgress(value: report.destination.availableBytes == 0 ? 1 : min(1, Double(report.requiredBytes) / Double(report.destination.availableBytes)), color: report.destination.availableBytes >= report.requiredBytes ? Studio.muted.opacity(0.5) : Studio.red)
                    Text(report.destination.canonicalPath).font(Studio.mono).foregroundStyle(Studio.muted).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }.padding(16)
            }

            if report.issues.isEmpty {
                StudioPanel(title: "PREFLIGHT INTEGRITY", accessory: "Inspection complete") {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                        integrity("All media / XML pairs matched")
                        integrity("Source files readable")
                        integrity("Destination writable")
                        integrity("Filesystem supports planned sizes")
                        integrity("Sufficient free capacity")
                        integrity("No output name collisions")
                    }.padding(16)
                    Text("SHA-256 verification runs during creation. Preflight does not certify delivered bytes.")
                        .font(.system(size: 10)).foregroundStyle(Studio.muted).padding(.horizontal, 16).padding(.bottom, 14)
                }
            }

            StudioPanel(title: "INDEPENDENT ZIP ARCHIVES", accessory: "\(report.archives.count) planned") {
                if report.archives.isEmpty {
                    Text("An archive plan is available after blocking source issues are resolved.")
                        .font(Studio.body).foregroundStyle(Studio.muted).padding(18)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(report.archives.enumerated()), id: \.element.id) { index, archive in
                            ArchivePlanRow(archive: archive, index: index + 1, state: archiveState(archive.name), record: job?.archives.first { $0.plan.name == archive.name })
                        }
                    }
                }
            }
            inventory
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10))
                Text("Analyzed \(report.analyzedAt.formatted(date: .abbreviated, time: .standard))")
                Spacer()
                Text("Predicted ZIP sizes include archive overhead.")
            }.font(.system(size: 10)).foregroundStyle(Studio.muted)
        }
    }
    private func archiveState(_ name: String) -> ArchiveState? {
        progress?.archiveStates[name] ?? job?.archives.first { $0.plan.name == name }?.state
    }
    private func integrity(_ text: String) -> some View {
        HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Studio.teal).font(.system(size: 11)); Text(text).font(.system(size: 11)).foregroundStyle(Studio.text) }
    }
    private var inventory: some View {
        StudioPanel(title: "SOURCE FILE INVENTORY", accessory: "Nothing silently omitted") {
            VStack(alignment: .leading, spacing: 0) {
                Button { inventoryExpanded.toggle() } label: {
                    HStack {
                        Image(systemName: inventoryExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                        Text("\(mediaCount) media"); Text("·").foregroundStyle(Studio.muted)
                        Text("\(xmlCount) XML"); Text("·").foregroundStyle(Studio.muted)
                        Text("\(unmatched.count) unmatched").foregroundStyle(unmatched.isEmpty ? Studio.muted : Studio.red)
                        Text("·").foregroundStyle(Studio.muted)
                        Text("\(unexpected.count) unexpected / hidden").foregroundStyle(unexpected.isEmpty ? Studio.muted : Studio.amber)
                        Spacer(minLength: 0)
                    }.font(.system(size: 11)).padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(inventoryExpanded ? "Collapse" : "Expand") source file inventory")
                if inventoryExpanded {
                    HStack {
                        Picker("Inventory filter", selection: $inventoryFilter) {
                            Text("All files").tag("All files")
                            Text("Unmatched").tag("Unmatched")
                            Text("Unexpected").tag("Unexpected")
                        }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 380)
                        Spacer()
                        Text("\(displayedFiles.count) entries").font(Studio.mono).foregroundStyle(Studio.muted)
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                    if displayedFiles.isEmpty { Text("No entries in this category.").font(Studio.body).foregroundStyle(Studio.muted).padding(16) }
                    LazyVStack(spacing: 0) {
                        ForEach(displayedFiles) { file in
                            HStack(spacing: 10) {
                                Image(systemName: file.kind == .media ? "film" : file.kind == .xml ? "doc.text" : "questionmark.folder").foregroundStyle(file.kind == .media || file.kind == .xml ? Studio.muted : Studio.amber).frame(width: 15)
                                Text(file.relativePath).font(Studio.mono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(file.kind.rawValue.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 70, alignment: .trailing)
                                Text(Studio.bytes(file.size)).font(Studio.mono).foregroundStyle(Studio.muted).frame(width: 85, alignment: .trailing)
                            }.padding(.horizontal, 17).padding(.vertical, 10).modifier(HoverSurface())
                                .overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }
}

struct ArchivePlanRow: View {
    let archive: ArchivePlan
    let index: Int
    let state: ArchiveState?
    let record: ArchiveRecord?
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Studio.muted).frame(width: 10)
                    Text(String(format: "%02d", index)).font(Studio.mono).foregroundStyle(Studio.muted.opacity(0.55)).frame(width: 22)
                    Image(systemName: state == .verified ? "checkmark.seal" : "doc.zipper").font(.system(size: 18, weight: .light)).foregroundStyle(state == .verified ? Studio.teal : Studio.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(archive.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Studio.text)
                        Text("\(archive.packages.count) clip \(archive.packages.count == 1 ? "package" : "packages") · \(archive.files.count) files").font(.system(size: 10)).foregroundStyle(Studio.muted)
                    }
                    Spacer()
                    if let state { StatusTag(title: state.rawValue, color: Studio.color(state)) }
                    else if archive.oversized { StatusTag(title: "Oversized", color: Studio.amber) }
                    Text(Studio.bytes(record?.actualBytes ?? archive.predictedBytes)).font(Studio.mono).foregroundStyle(Studio.text).frame(width: 90, alignment: .trailing)
                }.padding(.horizontal, 15).padding(.vertical, 15).contentShape(Rectangle()).modifier(HoverSurface())
            }.buttonStyle(.plain).accessibilityLabel("\(archive.name), \(archive.packages.count) clip \(archive.packages.count == 1 ? "package" : "packages"), \(Studio.bytes(archive.predictedBytes)), \(expanded ? "collapse" : "expand")")
            if expanded {
                VStack(spacing: 0) {
                    ForEach(archive.packages) { package in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "link").font(.system(size: 10)).foregroundStyle(Studio.teal.opacity(0.65))
                                Text(package.basename).font(Studio.mono)
                                Spacer()
                                Text(Studio.bytes(package.totalSize)).font(Studio.mono).foregroundStyle(Studio.muted)
                            }
                            ForEach(package.files) { file in
                                HStack(spacing: 8) {
                                    Text(file.kind == .media ? "MEDIA" : "XML").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 37, alignment: .leading)
                                    Text(file.relativePath).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer()
                                    if state == .verified { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(Studio.teal).help("Archive member SHA-256 matched the source") }
                                    Text(Studio.bytes(file.size)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                                }.padding(.leading, 18)
                            }
                        }.padding(.vertical, 13).padding(.horizontal, 20)
                            .overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
                    }
                    if let hash = record?.sha256 {
                        HStack(alignment: .top) { Eyebrow(title: "ZIP SHA-256", color: Studio.teal); Text(hash).font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }.padding(15)
                    }
                    if let failure = record?.failure { Notice(title: "ARCHIVE FAILURE", text: failure, color: Studio.red).padding(12) }
                }.padding(.leading, 35).background(Studio.canvas.opacity(0.45))
            }
        }.overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
}
