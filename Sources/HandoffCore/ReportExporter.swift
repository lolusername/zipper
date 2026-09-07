import Foundation

/// Keeps report export within the same source protection boundary as archive creation,
/// including verification sessions that never selected a source in the sidebar.
public enum ReportExporter {
    public static func write(_ data: Data, to url: URL, protectedSourcePaths: [String],
                             expectedSourceIdentities: [String: FileIdentity] = [:]) throws {
        let paths = Array(Set(protectedSourcePaths.filter { !$0.isEmpty }))
        guard !paths.isEmpty else {
            throw HandoffError.blocked("The original source location is unknown. Verify the handoff again before exporting its report.")
        }
        var sources: [ReadOnlySource] = []
        for path in paths {
            let source: ReadOnlySource
            do { source = try ReadOnlySource(url: URL(fileURLWithPath: path)) }
            catch {
                throw HandoffError.blocked("The original source location cannot be checked. Reconnect the source before exporting a report so the app can prove the save location is separate. Delivery verification itself does not require the source.")
            }
            if let expected = expectedSourceIdentities[path], !sameObject(source.identity, expected) {
                throw HandoffError.blocked("The original source directory was replaced or moved. Restore its recorded location before exporting a report; a matching folder name is not sufficient.")
            }
            sources.append(source)
        }
        let destination = try Destination(url: url.deletingLastPathComponent(), additionalSources: sources)
        try destination.writeAtomic(data, name: url.lastPathComponent, replace: false)
    }
}
