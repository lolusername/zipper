import Foundation
import AppKit
import SwiftUI
import HandoffCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var destinationPath = ""
    @Published var prefix = "FOOTAGE"
    @Published var modeIndex = 0
    @Published var maxGB = "25"
    @Published var archiveCount = "8"
    @Published var acknowledgedOversized = false
    @Published var deepVerification = true
    @Published var preflight: PreflightReport?
    @Published var job: JobRecord?
    @Published var progress: JobProgress?
    @Published var verification: VerificationReport?
    @Published var error: String?
    @Published var isBusy = false
    @Published var isAnalyzing = false
    @Published var isVerifying = false
    @Published private(set) var hasInterruptedJob = false
    private var cancellation = CancellationToken()
    private var activity: NSObjectProtocol?
    private var accessURLs: [URL] = []
    private var verificationDestination: URL?
    private var lastConfiguration: JobConfiguration?
    private var recoveryGeneration = UUID()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "Zipper.lastDestination") {
            destinationPath = saved
            restoreAccess(bookmarkKey:"Zipper.destinationBookmark",expectedPath:saved,isSource:false)
        }
        if let saved = UserDefaults.standard.string(forKey: "Zipper.lastSource") {
            sourcePath=saved
            restoreAccess(bookmarkKey:"Zipper.sourceBookmark",expectedPath:saved,isSource:true)
        }
    }
    var canAnalyze: Bool { !isBusy && !sourcePath.isEmpty && !destinationPath.isEmpty }
    var canStart: Bool {
        guard !isBusy, error == nil, job == nil, var report=preflight, report.issues.isEmpty, let configuration=try? configuration() else { return false }
        report.configuration.acknowledgedOversized = acknowledgedOversized
        var approved = report.configuration
        approved.acknowledgedOversized = configuration.acknowledgedOversized
        return report.canCreate && approved == configuration
    }
    func invalidatePreflight() {
        guard !isBusy else { return }
        preflight=nil; job=nil; progress=nil; verification=nil; error=nil; verificationDestination=nil
        acknowledgedOversized=false
    }
    func chooseSource() {
        if let url=chooseDirectory(title: "Choose camera originals", message: "SOURCE — READ ONLY. Select a flat folder of media and XML/BIM sidecars. MXF + M01.XML + R01.BIM groups are supported.") {
            invalidatePreflight(); sourcePath=url.path
            UserDefaults.standard.set(url.path,forKey:"Zipper.lastSource")
            rememberAccess(url,bookmarkKey:"Zipper.sourceBookmark",readOnly:true)
        }
    }
    func chooseDestination() {
        if let url=chooseDirectory(title: "Choose delivery destination", message: "DESTINATION — WRITABLE OUTPUT. Choose a separate, existing folder.") {
            invalidatePreflight(); destinationPath=url.path
            UserDefaults.standard.set(url.path,forKey:"Zipper.lastDestination")
            rememberAccess(url,bookmarkKey:"Zipper.destinationBookmark",readOnly:false)
            inspectRecovery()
        }
    }
    private func chooseDirectory(title: String, message: String) -> URL? {
        let panel=NSOpenPanel()
        panel.title=title; panel.message=message; panel.canChooseDirectories=true; panel.canChooseFiles=false
        panel.allowsMultipleSelection=false; panel.canCreateDirectories=false; panel.prompt="Choose Folder"
        guard panel.runModal() == .OK, let url=panel.url else { return nil }
        if url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
        return url
    }
    private func configuration() throws -> JobConfiguration {
        let mode: BatchingMode
        if modeIndex == 0 {
            guard let gb=Double(maxGB), gb.isFinite, gb > 0, gb <= 10_000 else { throw HandoffError.blocked("Enter a maximum size greater than 0 and at most 10,000 GB (decimal gigabytes).") }
            let count = gb * 1_000_000_000
            guard count >= 1 else { throw HandoffError.blocked("Maximum ZIP size must be at least one byte.") }
            mode = .maximumBytes(UInt64(count.rounded(.down)))
        } else {
            guard let count=Int(archiveCount), count > 0 else { throw HandoffError.blocked("Enter a positive whole number of archives.") }
            mode = .archiveCount(count)
        }
        return JobConfiguration(sourcePath: sourcePath, destinationPath: destinationPath, prefix: prefix, mode: mode, acknowledgedOversized: acknowledgedOversized)
    }
    func analyze() {
        guard !isBusy else { return }
        do {
            let config=try configuration()
            begin(operation:"Analyzing · no destination writes")
            isAnalyzing=true; preflight=nil; job=nil; verification=nil
            let token=cancellation
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result=Result { try Preflight.analyze(config,cancellation:token) }
                Task { @MainActor in
                    guard let self else { return }; self.end()
                    switch result {
                    case .success(let report): self.preflight=report; self.lastConfiguration=config
                    case .failure(let failure): self.error=failure.localizedDescription
                    }
                }
            }
        } catch { self.error=error.localizedDescription }
    }
    func start() {
        guard canStart, var report=preflight else { return }
        report.configuration.acknowledgedOversized=acknowledgedOversized
        let destination=URL(fileURLWithPath:destinationPath)
        verificationDestination=nil
        begin(operation:"Preparing verified handoff")
        job=JobRecord(preflight:report); verification=nil
        let token=cancellation
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { try JobEngine().create(preflight:report,cancellation:token) { value in Task { @MainActor in self?.progress=value } } }
            Task { @MainActor in self?.finishJob(result,destination:destination) }
        }
    }
    func resume() {
        guard !isBusy else { return }
        if destinationPath.isEmpty { chooseDestination() }
        guard !destinationPath.isEmpty else { return }
        let destination=URL(fileURLWithPath:destinationPath)
        verificationDestination=nil
        job=nil
        begin(operation:"Recovering and revalidating handoff")
        verification=nil
        let token=cancellation
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { try JobEngine().resume(destinationURL:destination,cancellation:token) { value in Task { @MainActor in self?.progress=value } } }
            Task { @MainActor in self?.finishJob(result,destination:destination) }
        }
    }
    private func finishJob(_ result: Result<JobRecord,Error>, destination: URL) {
        end()
        switch result {
        case .success(let completed): job=completed; preflight=completed.preflight; sourcePath=completed.preflight.configuration.sourcePath
        case .failure(let failure):
            error=failure.localizedDescription
            job?.status = (failure as? HandoffError) == .cancelled ? .interrupted : .failed
            job?.finalSourceVerified=false
            job?.failure=failure.localizedDescription
        }
        inspectRecovery()
    }
    func cancel() { cancellation.cancel(); progress?.operation="Stopping safely at the next I/O boundary…" }
    func verifyExisting() {
        guard !isBusy, let url=chooseDirectory(title:"Verify Existing Handoff", message:"Select the delivery folder containing HANDOFF_MANIFEST.json. Original media is not required. Verification writes nothing.") else { return }
        job=nil; preflight=nil
        runVerification(url)
    }
    func verifyAgain() {
        guard !isBusy else { return }
        if let url=verificationDestination { runVerification(url) }
        else if !destinationPath.isEmpty { runVerification(URL(fileURLWithPath:destinationPath)) }
    }
    private func runVerification(_ url: URL) {
        verificationDestination=url
        verification=nil
        begin(operation:"Checking delivery integrity")
        isVerifying=true
        let token=cancellation, deep=deepVerification
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result { try HandoffVerifier.verify(destinationURL:url,deep:deep,cancellation:token) { value in Task { @MainActor in self?.progress=value } } }
            Task { @MainActor in
                guard let self else { return }; self.end()
                switch result {
                case .success(let report): self.verification=report
                case .failure(let failure): self.error=failure.localizedDescription
                }
            }
        }
    }
    func reveal() {
        let path=verificationDestination?.path ?? job?.preflight.destination.canonicalPath ?? destinationPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath:path,isDirectory:true))
    }
    func exportReport() {
        let text: String
        if let verification {
            text="ZIPPER — DELIVERY CHECK\nChecked: \(ISO8601DateFormatter().string(from:verification.checkedAt))\nResult: \(verification.passed ? "PASS" : "FAIL")\nArchives verified: \(verification.checkedArchives)\nDeep member verification: \(verification.deep ? "Yes" : "No")\nMembers verified: \(verification.checkedFiles)\n\(verification.issues.joined(separator:"\n"))\n"
        } else if let job {
            let formatter=ISO8601DateFormatter()
            text=JobEngine.humanReport(job) + "\nAUDIT LOG\n" + job.events.map { "\(formatter.string(from:$0.timestamp))  \($0.message)" }.joined(separator:"\n") + "\n"
        }
        else { return }
        let panel=NSSavePanel(); panel.title="Export Delivery Report"; panel.nameFieldStringValue="Zipper-Verification-Report.txt"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            // Export is also constrained by the source/destination separation gate.
            let source = sourcePath.isEmpty ? nil : try ReadOnlySource(url:URL(fileURLWithPath:sourcePath))
            let destination = try Destination(url:url.deletingLastPathComponent(),source:source)
            try destination.writeAtomic(Data(text.utf8),name:url.lastPathComponent,replace:false)
        } catch { self.error=error.localizedDescription }
    }
    func reset() {
        guard !isBusy else { return }
        invalidatePreflight(); inspectRecovery()
    }
    private func rememberAccess(_ url: URL, bookmarkKey: String, readOnly: Bool) {
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let options: URL.BookmarkCreationOptions = readOnly ? [.withSecurityScope,.securityScopeAllowOnlyReadAccess] : [.withSecurityScope]
            let bookmark=(try? url.bookmarkData(options:options,includingResourceValuesForKeys:nil,relativeTo:nil)) ?? (try? url.bookmarkData(options:[.minimalBookmark],includingResourceValuesForKeys:nil,relativeTo:nil))
            Task { @MainActor in
                guard let self, (readOnly ? self.sourcePath : self.destinationPath)==url.path, let bookmark else { return }
                UserDefaults.standard.set(bookmark,forKey:bookmarkKey)
            }
        }
    }
    private func restoreAccess(bookmarkKey: String, expectedPath: String, isSource: Bool) {
        // Bookmark resolution and removable-volume inspection must never stall window creation.
        guard let bookmark=UserDefaults.standard.data(forKey:bookmarkKey) else { return }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var stale=false
            let resolved=(try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale)) ?? (try? URL(resolvingBookmarkData:bookmark,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale))
            let accessed=resolved?.startAccessingSecurityScopedResource() ?? false
            Task { @MainActor in
                guard let self, (isSource ? self.sourcePath : self.destinationPath)==expectedPath else { if accessed { resolved?.stopAccessingSecurityScopedResource() }; return }
                if let resolved, !stale {
                    if accessed { self.accessURLs.append(resolved) }
                    if isSource { self.sourcePath=resolved.path }
                    else { self.destinationPath=resolved.path; self.inspectRecovery() }
                } else if accessed { resolved?.stopAccessingSecurityScopedResource() }
            }
        }
    }
    private func inspectRecovery() {
        hasInterruptedJob=false
        let path=destinationPath
        guard !path.isEmpty else { return }
        let generation=UUID(); recoveryGeneration=generation
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let record=try? JobEngine.loadState(destinationURL:URL(fileURLWithPath:path))
            Task { @MainActor in
                guard let self, self.recoveryGeneration==generation, self.destinationPath==path else { return }
                self.hasInterruptedJob=record.map { $0.status != .completed } ?? false
            }
        }
    }
    private func begin(operation: String) {
        cancellation=CancellationToken(); error=nil; isBusy=true
        progress=JobProgress(operation:operation)
        activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Verifying a camera-original media handoff")
    }
    private func end() {
        isBusy=false; isAnalyzing=false; isVerifying=false
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity=nil }
    }
}
