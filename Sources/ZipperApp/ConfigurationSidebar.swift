import SwiftUI

struct ConfigurationSidebar: View {
    @ObservedObject var model: AppModel
    private var locked: Bool { model.isBusy || model.isAnalyzing }
    private var creationHint: String {
        if model.isAnalyzing { return "Preflight inspects only. It writes nothing." }
        if model.isVerifying { return "Reading delivery bytes for verification." }
        if model.isBusy { return "Running the approved handoff. Source stays read only." }
        if model.job?.status == .completed { return "Handoff complete. Start a new handoff to package more files." }
        if model.job != nil { return "Incomplete output is preserved. Resume to revalidate." }
        if model.preflight == nil { return "Preflight inspects only. It writes nothing." }
        return model.canStart ? "Plan approved for creation. Source remains read only." : "Resolve all blocking checks before creation."
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    location(title: "SOURCE — READ ONLY", path: model.sourcePath, icon: "sdcard", prompt: "Choose source directory", action: model.chooseSource)
                    location(title: "DESTINATION — WRITABLE OUTPUT", path: model.destinationPath, icon: "externaldrive", prompt: "Choose output directory", action: model.chooseDestination)
                    Rectangle().fill(Studio.line).frame(height: 1)
                    packaging
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(title: "ARCHIVE NAME PREFIX")
                        StudioTextField(placeholder: "FOOTAGE", text: $model.prefix, label: "Archive name prefix").disabled(locked)
                        Text("\(model.prefix.isEmpty ? "FOOTAGE" : model.prefix)_001.zip")
                            .font(Studio.mono).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "link").foregroundStyle(Studio.teal)
                        Text("Media + XML stay together.").foregroundStyle(Studio.muted)
                    }.font(.system(size: 11))
                }.padding(18)
            }
            VStack(spacing: 10) {
                Button(action: model.analyze) {
                    HStack { if model.isAnalyzing { ProgressView().controlSize(.mini) } else { Image(systemName: "viewfinder") }; Text(model.isAnalyzing ? "ANALYZING…" : "ANALYZE / PREFLIGHT"); Spacer(); if !model.isAnalyzing { Text("⌘R").foregroundStyle(Studio.muted) } }.frame(maxWidth: .infinity)
                }.buttonStyle(StudioButtonStyle()).disabled(!model.canAnalyze)
                Button(action: model.start) {
                    HStack(spacing: 7) { Image(systemName: "checkmark.shield"); Text("CREATE VERIFIED HANDOFF") }.frame(maxWidth: .infinity)
                }.buttonStyle(StudioButtonStyle(kind: .primary)).disabled(!model.canStart)
                    .help("Available after preflight passes and all required acknowledgments are made. Command-Return to start.")
                Text(creationHint)
                    .font(.system(size: 10)).foregroundStyle(Studio.muted).multilineTextAlignment(.center).frame(minHeight: 26)
            }.padding(14).background(Studio.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(title: "DELIVERY CHECK")
                Button(action: model.verifyExisting) {
                    HStack { Image(systemName: "checkmark.seal"); Text("VERIFY EXISTING HANDOFF"); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)) }.frame(maxWidth: .infinity)
                }.buttonStyle(StudioButtonStyle(kind: .quiet)).disabled(locked)
                Toggle(isOn: $model.deepVerification) { Text("Also verify every archive member").font(.system(size: 11)).foregroundStyle(Studio.muted) }
                    .toggleStyle(.checkbox).tint(Studio.teal).disabled(locked)
                    .help("Reopen each ZIP and compare every member’s SHA-256 with the manifest. Original source is not required.")
                if model.hasInterruptedJob {
                    Button(action: model.resume) {
                        Label("RESUME VERIFIED HANDOFF", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(StudioButtonStyle()).foregroundStyle(Studio.amber).disabled(locked)
                } else {
                    Button("Resume an interrupted handoff…", action: model.resume)
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Studio.muted).disabled(locked)
                        .help("Select a destination containing a persisted Zipper job. Existing verified ZIPs are rechecked before reuse.")
                }
            }.padding(16).background(Studio.canvas.opacity(0.4))
        }
        .frame(width: 306)
        .background(Studio.sidebar)
        .onChange(of: model.prefix) { _, _ in model.invalidatePreflight() }
        .onChange(of: model.modeIndex) { _, _ in model.invalidatePreflight() }
        .onChange(of: model.maxGB) { _, _ in model.invalidatePreflight() }
        .onChange(of: model.archiveCount) { _, _ in model.invalidatePreflight() }
    }

    private var packaging: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(title: "PACKAGING")
            HStack(spacing: 3) {
                modeButton("Maximum size", index: 0)
                modeButton("Archive count", index: 1)
            }.padding(3).background(Studio.canvas).clipShape(RoundedRectangle(cornerRadius: 5))
            if model.modeIndex == 0 {
                HStack(spacing: 10) {
                    StudioTextField(placeholder: "25", text: $model.maxGB, label: "Maximum ZIP size in gigabytes")
                    Text("GB").font(Studio.mono).foregroundStyle(Studio.muted)
                }.disabled(locked)
                Text("Hard ceiling per ZIP. An indivisible oversized clip requires acknowledgment.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    StudioTextField(placeholder: "8", text: $model.archiveCount, label: "Exact number of ZIP archives")
                    Text("ZIPs").font(Studio.mono).foregroundStyle(Studio.muted)
                }.disabled(locked)
                Text("Exactly this many nonempty ZIPs, balanced by size. Clip packages are never split.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modeButton(_ label: String, index: Int) -> some View {
        Button { model.modeIndex = index } label: {
            Text(label).font(.system(size: 11, weight: model.modeIndex == index ? .semibold : .regular))
                .foregroundStyle(model.modeIndex == index ? Studio.text : Studio.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(model.modeIndex == index ? Studio.raised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }.buttonStyle(.plain).disabled(locked)
            .accessibilityAddTraits(model.modeIndex == index ? .isSelected : [])
    }

    private func location(title: String, path: String, icon: String, prompt: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title: title, color: title.hasPrefix("SOURCE") ? Studio.teal : Studio.muted)
            Button(action: action) {
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(path.isEmpty ? Studio.muted : Studio.text).frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(path.isEmpty ? prompt : URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Studio.text).lineLimit(1).truncationMode(.middle)
                        Text(path.isEmpty ? "Select folder…" : path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Studio.muted)
                }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(10)
                    .background(Studio.canvas.opacity(0.65))
                    .modifier(HoverSurface())
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Studio.line, lineWidth: 1))
            }.buttonStyle(.plain).disabled(locked).help(path.isEmpty ? prompt : path)
                .accessibilityLabel(title).accessibilityValue(path.isEmpty ? "No directory selected" : path)
        }
    }
}
