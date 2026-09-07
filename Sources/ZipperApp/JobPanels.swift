import SwiftUI
import HandoffCore

struct LiveJobPanel: View {
    let job: JobRecord
    let progress: JobProgress?
    let busy: Bool
    let cancel: () -> Void
    let resume: () -> Void
    @State private var showLog = false
    private var fraction: Double { min(0.999, max(0, progress?.fraction ?? 0)) }
    private var verifiedCount: Int { progress?.verifiedArchives ?? job.archives.filter { $0.state == .verified }.count }
    private var status: String {
        if busy { return progress?.operation ?? "Preparing handoff" }
        return job.status == .failed ? "Handoff stopped" : "Handoff interrupted"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(title: busy ? "LIVE HANDOFF / VERIFICATION REQUIRED" : "RECOVERY / VERIFIED OUTPUTS PRESERVED", color: busy ? Studio.teal : Studio.amber)
                    Text(status).font(.system(size: 25, weight: .medium)).tracking(-0.3)
                }
                Spacer()
                if busy {
                    Button(action: cancel) { Label("CANCEL JOB", systemImage: "stop.fill") }.buttonStyle(StudioButtonStyle(kind: .danger))
                        .help("Stop safely. Verified ZIPs are preserved and incomplete output remains .partial.")
                } else {
                    Button(action: resume) { Label("Resume Handoff", systemImage: "arrow.clockwise") }.buttonStyle(StudioButtonStyle())
                }
            }
            StudioPanel(title: "OVERALL PROGRESS", accessory: "\(Int(fraction * 100))%") {
                VStack(alignment: .leading, spacing: 18) {
                    FineProgress(value: fraction, color: busy ? Studio.teal : Studio.amber)
                    HStack {
                        Text("\(verifiedCount) / \(job.archives.count) archives verified").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text("Delivery awaits final source verification").font(.system(size: 10)).foregroundStyle(Studio.muted)
                    }
                    Rectangle().fill(Studio.line).frame(height: 1)
                    if let progress {
                        HStack(alignment: .top, spacing: 20) {
                            Metric(label: "BYTES READ", value: Studio.bytes(progress.bytesRead))
                            Metric(label: "BYTES WRITTEN", value: Studio.bytes(progress.bytesWritten))
                            Metric(label: "VERIFIED BYTES", value: Studio.bytes(progress.verifiedBytes), tint: Studio.teal)
                        }
                        HStack(spacing: 18) {
                            Label(Studio.elapsed(progress.elapsed), systemImage: "clock")
                            Text("READ \(Studio.bytes(progress.elapsed > 0 ? UInt64(Double(progress.bytesRead) / progress.elapsed) : 0))/s average")
                            Spacer()
                        }.font(Studio.mono).foregroundStyle(Studio.muted)
                    }
                }.padding(17)
            }
            if let progress, !progress.currentArchive.isEmpty || !progress.currentFile.isEmpty {
                StudioPanel(title: "CURRENT OPERATION", accessory: busy ? "Active" : "Stopped safely") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "doc.zipper").font(.system(size: 24, weight: .light)).foregroundStyle(Studio.teal)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(progress.currentArchive.isEmpty ? "Source verification" : progress.currentArchive).font(.system(size: 15, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(progress.operation).font(.system(size: 11)).foregroundStyle(Studio.muted)
                            }
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                        }
                        if let state = progress.archiveStates[progress.currentArchive] {
                            lifecycle(state)
                        }
                        if !progress.currentFile.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "doc").foregroundStyle(Studio.muted)
                                Text(progress.currentFile).font(Studio.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }.padding(11).background(Studio.canvas).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }.padding(17)
                }
            }
            if !busy {
                Notice(title: "NOT A COMPLETE DELIVERY", text: job.failure ?? "This job has not completed every required verification. Already verified archives remain on the destination. Resume rechecks existing ZIP hashes and source identity before continuing.")
            }
            if !job.events.isEmpty {
                StudioPanel(title: "AUDIT TRAIL", accessory: "\(job.events.count) events") {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { showLog.toggle() } label: {
                            HStack { Image(systemName: showLog ? "chevron.down" : "chevron.right").font(.system(size: 9)); Text(showLog ? "Hide job events" : "Inspect job events"); Spacer() }.font(.system(size: 11)).padding(15).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showLog {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(job.events) { event in
                                    HStack(alignment: .top, spacing: 13) {
                                        Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 75, alignment: .leading)
                                        Text(event.message).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }.padding(15).padding(.top, -5)
                        }
                    }
                }
            }
        }
    }
    private func lifecycle(_ state: ArchiveState) -> some View {
        let stages: [(ArchiveState, String)] = [(.hashingSource, "Source hash"), (.writing, "Write ZIP"), (.verifyingContents, "Verify members"), (.hashingArchive, "Hash ZIP"), (.verified, "Verified")]
        let active = stages.firstIndex { $0.0 == state } ?? -1
        return HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, entry in
                VStack(alignment: .leading, spacing: 7) {
                    Rectangle().fill(index <= active ? Studio.teal.opacity(index == active ? 1 : 0.35) : Studio.line).frame(height: 3)
                    HStack(spacing: 4) {
                        if index < active || state == .verified { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        Text(entry.1).font(.system(size: 9, weight: index == active ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                    }.foregroundStyle(index == active ? Studio.teal : Studio.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityLabel("Archive stage: \(state.rawValue). Writing and verification are separate required stages.")
    }
}

struct CompletionPanel: View {
    let job: JobRecord
    let reveal: () -> Void
    let verify: () -> Void
    let export: () -> Void
    let disabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 38, weight: .light)).foregroundStyle(Studio.teal)
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(title: "VERIFIED HANDOFF READY", color: Studio.teal)
                    Text("Every source byte accounted for.").font(.system(size: 25, weight: .medium)).tracking(-0.4)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 18) {
                Metric(label: "ARCHIVES VERIFIED", value: "\(job.archives.count) / \(job.archives.count)", tint: Studio.teal)
                Metric(label: "SOURCE FILES VERIFIED", value: "\(job.preflight.files.count) / \(job.preflight.files.count)", tint: Studio.teal)
                Metric(label: "SOURCE ACCOUNTED FOR", value: Studio.bytes(job.preflight.totalBytes))
            }
            HStack(spacing: 18) {
                Label("0 missing files", systemImage: "checkmark.circle").foregroundStyle(Studio.teal)
                Label("0 hash mismatches", systemImage: "checkmark.circle").foregroundStyle(Studio.teal)
                Spacer()
            }.font(.system(size: 11))
            Rectangle().fill(Studio.teal.opacity(0.2)).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(title: "DESTINATION")
                Text(job.preflight.destination.canonicalPath).font(Studio.mono).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(Studio.muted)
                    Text("HANDOFF_MANIFEST.txt").font(Studio.mono)
                    Text("+ JSON + SHA256SUMS.txt").font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
            }
            HStack(spacing: 9) {
                Button(action: reveal) { Label("Reveal in Finder", systemImage: "folder") }.buttonStyle(StudioButtonStyle(kind: .primary))
                Button(action: verify) { Label("Verify Handoff Again", systemImage: "checkmark.seal") }.buttonStyle(StudioButtonStyle())
                Button(action: export) { Label("Export Report", systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
            }.disabled(disabled)
            Text("Source SHA-256 rechecked after packaging. Each ZIP was independently reopened and verified before delivery.")
                .font(.system(size: 10)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(22).background(Studio.teal.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Studio.teal.opacity(0.25), lineWidth: 1))
    }
}

struct VerificationResultPanel: View {
    let report: VerificationReport
    let reveal: () -> Void
    let export: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: report.passed ? "checkmark.seal.fill" : "xmark.octagon.fill").font(.system(size: 26, weight: .light)).foregroundStyle(report.passed ? Studio.teal : Studio.red)
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(title: "INDEPENDENT DELIVERY CHECK", color: Studio.muted)
                    Text(report.passed ? "Handoff verification passed" : "Handoff verification failed").font(.system(size: 20, weight: .medium))
                }
                Spacer()
                StatusTag(title: report.deep ? "Deep verification" : "Archive hashes", color: report.passed ? Studio.teal : Studio.red)
            }
            HStack(spacing: 20) {
                Text("\(report.checkedArchives) ZIPs checked").font(Studio.mono)
                if report.deep { Text("\(report.checkedFiles) members checked").font(Studio.mono) }
                Spacer()
                Text(report.checkedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Studio.muted)
            }
            Text(report.deep ? "ZIP hashes and archived member hashes were compared with the delivery manifest. This check does not require the original source." : "Complete ZIP SHA-256 values were compared with the delivery manifest. Member-level verification was not requested.")
                .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                Notice(title: "VERIFICATION ISSUE", text: issue, color: Studio.red)
            }
            HStack(spacing: 9) {
                Button(action: reveal) { Label("Reveal in Finder", systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                Button(action: export) { Label("Export Report", systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
            }
        }.padding(19).background(Studio.surface).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder((report.passed ? Studio.teal : Studio.red).opacity(0.3), lineWidth: 1))
    }
}

struct StandaloneVerificationProgress: View {
    let progress: JobProgress
    let cancel: () -> Void
    var body: some View {
        StudioPanel(title: "VERIFY EXISTING HANDOFF", accessory: "Reading delivered bytes") {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress.operation).font(.system(size: 20, weight: .medium))
                    Spacer()
                    Button("Cancel", action: cancel).buttonStyle(StudioButtonStyle(kind: .danger))
                }
                FineProgress(value: min(0.999, progress.fraction))
                Text(progress.currentArchive.isEmpty ? "Checking delivery manifest…" : progress.currentArchive).font(Studio.mono).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 18) {
                    Metric(label: "ARCHIVES CHECKED", value: "\(progress.verifiedArchives) / \(progress.totalArchives)")
                    Metric(label: "VERIFIED BYTES", value: Studio.bytes(progress.verifiedBytes), tint: Studio.teal)
                    Metric(label: "ELAPSED", value: Studio.elapsed(progress.elapsed))
                }
            }.padding(19)
        }
    }
}
