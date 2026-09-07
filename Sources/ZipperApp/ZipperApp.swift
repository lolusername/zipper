import SwiftUI
import AppKit
import Combine

@main
struct ZipperApplication: App {
    @NSApplicationDelegateAdaptor(ZipperApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .onAppear { appDelegate.model = model }
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Handoff") { model.reset() }.keyboardShortcut("n").disabled(model.isBusy || model.isAnalyzing)
                Button("Choose Source…") { model.chooseSource() }.keyboardShortcut("o").disabled(model.isBusy || model.isAnalyzing)
                Button("Choose Destination…") { model.chooseDestination() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isBusy || model.isAnalyzing)
            }
            CommandMenu("Handoff") {
                Button("Analyze / Preflight") { model.analyze() }.keyboardShortcut("r").disabled(!model.canAnalyze)
                Button("Create Verified Handoff") { model.start() }.keyboardShortcut(.return, modifiers: [.command]).disabled(!model.canStart)
                Divider()
                Button("Verify Existing Handoff…") { model.verifyExisting() }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(model.isBusy || model.isAnalyzing)
                Button("Resume Verified Handoff") { model.resume() }.disabled(model.isBusy || model.isAnalyzing)
                Divider()
                Button("Cancel Job") { model.cancel() }.disabled(!model.isBusy)
            }
        }
    }
}

@MainActor
final class ZipperApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationObservation: AnyCancellable?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        model.cancel()
        terminationObservation = model.$isBusy
            .drop(while: { $0 })
            .first()
            .sink { _ in sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
