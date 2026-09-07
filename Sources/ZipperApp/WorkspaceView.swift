import SwiftUI
import HandoffCore

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    private var ready: Bool {
        guard let job = model.job else { return false }
        return job.status == .completed && job.finalSourceVerified && !job.archives.isEmpty && job.archives.allSatisfy { $0.state == .verified } && !model.isBusy && model.error == nil && model.verification == nil
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Studio.line).frame(height: 1)
            HStack(spacing: 0) {
                ConfigurationSidebar(model: model)
                Rectangle().fill(Studio.line).frame(width: 1)
                ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.error {
                            Notice(title: model.job == nil ? "OPERATION BLOCKED" : "HANDOFF NEEDS ATTENTION", text: error, color: Studio.red)
                        }
                        if let verification = model.verification { VerificationResultPanel(report: verification, reveal: model.reveal, export: model.exportReport) }
                        if model.isAnalyzing {
                            StudioPanel(title: "ANALYZE / PREFLIGHT", accessory: "Read-only inspection") {
                                HStack(spacing: 14) {
                                    ProgressView().controlSize(.small)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text("Inspecting source and destination…").font(.system(size: 19, weight: .medium))
                                        Text("Matching media and sidecars, checking capacity and filesystem limits, and planning archives. No destination data is being written.").font(Studio.body).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Button("Cancel", action: model.cancel).buttonStyle(StudioButtonStyle(kind: .danger))
                                }.padding(19)
                            }
                        } else if model.isVerifying, let progress = model.progress {
                            StandaloneVerificationProgress(progress: progress, cancel: model.cancel)
                        } else if ready, let job = model.job {
                            CompletionPanel(job: job, reveal: model.reveal, verify: model.verifyAgain, export: model.exportReport, disabled: model.isBusy)
                        } else if let job = model.job, job.status != .completed, model.verification == nil {
                            LiveJobPanel(job: job, progress: model.progress, busy: model.isBusy, cancel: model.cancel, resume: model.resume)
                        } else if model.isBusy, let progress = model.progress {
                            StandaloneVerificationProgress(progress: progress, cancel: model.cancel)
                        }
                        if !model.isVerifying, model.verification == nil, let report = model.preflight ?? model.job?.preflight {
                            PreflightPanel(report: report, acknowledgedOversized: $model.acknowledgedOversized, job: model.job, progress: model.progress, locked: model.isBusy || model.isAnalyzing)
                        } else if model.job == nil && !model.isBusy && model.verification == nil {
                            emptyState
                        }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .topLeading).id("workspace-top")
                }.background(Studio.canvas)
                    .onChange(of: model.isBusy) { _, _ in
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.18)) { scrollProxy.scrollTo("workspace-top", anchor: .top) }
                        }
                    }
                }
            }
            footer
        }.background(Studio.canvas).foregroundStyle(Studio.text).font(Studio.body).tint(Studio.teal)
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 21, weight: .light)).foregroundStyle(Studio.teal)
            Text("Zipper").font(.system(size: 20, weight: .semibold)).tracking(-0.5)
            Rectangle().fill(Studio.line).frame(width: 1, height: 21).padding(.horizontal, 3)
            Eyebrow(title: "VERIFIED MEDIA HANDOFF")
            Spacer()
            if model.isAnalyzing { StatusTag(title: "Analyzing", color: Studio.amber, icon: "viewfinder") }
            else if model.isBusy { StatusTag(title: "Operation in progress", icon: "circle.dotted") }
            else if ready || model.verification?.passed == true { StatusTag(title: "Verified", icon: "checkmark.shield.fill") }
            else { StatusTag(title: "Source protected", color: Studio.muted, icon: "lock") }
            if model.preflight != nil || model.job != nil || model.verification != nil {
                Button(action: model.reset) { Label("New Handoff", systemImage: "plus") }
                    .buttonStyle(StudioButtonStyle(kind: .quiet)).disabled(model.isBusy || model.isAnalyzing)
            }
        }.padding(.leading, 82).padding(.trailing, 22).frame(height: 58).background(Studio.sidebar)
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Studio.teal)
            Text("READ SOURCE").foregroundStyle(Studio.muted)
            Image(systemName: "arrow.right").foregroundStyle(Studio.muted.opacity(0.5))
            Text("WRITE DESTINATION").foregroundStyle(Studio.muted)
            Spacer()
            Text("ZIP64").foregroundStyle(Studio.muted)
            Text("·").foregroundStyle(Studio.muted.opacity(0.4))
            Text("STORE").foregroundStyle(Studio.muted)
            Text("·").foregroundStyle(Studio.muted.opacity(0.4))
            Text("SHA-256").foregroundStyle(Studio.teal)
        }.font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.7).padding(.horizontal, 22).frame(height: 28)
            .background(Studio.sidebar).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(title: "CAMERA ORIGINALS. VERIFIED DELIVERY.", color: Studio.teal)
                Text("A handoff you can account for.").font(.system(size: 29, weight: .medium)).tracking(-0.6)
                Text("Package camera media and matching XML / BIM sidecars into independent ZIPs. Every file is checked against the source before an archive becomes deliverable.")
                    .font(.system(size: 13)).foregroundStyle(Studio.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
            }.padding(.top, 22)
            StudioPanel(title: "THE HANDOFF SEQUENCE", accessory: "4 integrity gates") {
                VStack(spacing: 0) {
                    sequence("01", title: "Inspect the source", detail: "Match media with its sidecars, account for every file, and inspect the exact archive plan.", symbol: "viewfinder")
                    sequence("02", title: "Hash and package", detail: "Read source bytes, calculate SHA-256, and write destination .partial files.", symbol: "arrow.right.doc.on.clipboard")
                    sequence("03", title: "Reopen and verify", detail: "Read every archived member and compare its SHA-256 with the source.", symbol: "checkmark.shield")
                    sequence("04", title: "Recheck the source", detail: "Confirm final source stability, then issue a complete audited handoff.", symbol: "checkmark.seal")
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle").foregroundStyle(Studio.muted)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start with a flat camera directory").font(.system(size: 12, weight: .medium))
                    Text("Each clip needs one media file and matching XML. MXF clips also support M01.XML and R01.BIM sidecars; matching BIM files are included whenever present. Exact-basename media / XML pairs still work. Unmatched, hidden, and unexpected files block preflight.")
                        .font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 2)
            HStack(spacing: 10) {
                Text("BASE.MXF").foregroundStyle(Studio.text)
                Image(systemName: "plus").foregroundStyle(Studio.muted)
                Text("BASEM01.XML").foregroundStyle(Studio.text)
                Image(systemName: "plus").foregroundStyle(Studio.muted)
                Text("BASER01.BIM").foregroundStyle(Studio.text)
                Spacer()
                StatusTag(title: "1 complete clip package", color: Studio.muted)
            }
                .font(Studio.mono).padding(15).background(Studio.surface.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
    private func sequence(_ number: String, title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(Studio.mono).foregroundStyle(Studio.muted.opacity(0.6)).frame(width: 20).padding(.top, 1)
            Image(systemName: symbol).font(.system(size: 16, weight: .light)).foregroundStyle(Studio.teal.opacity(0.85)).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 1).padding(.leading, 52) }
    }
}
