import Darwin
import Foundation

struct PackagingError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func isDirectoryIfPresent(_ path: String) throws -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0 else {
        if errno == ENOENT { return false }
        throw PackagingError("Cannot inspect \(path): \(String(cString: strerror(errno)))")
    }
    guard status.st_mode & S_IFMT == S_IFDIR else {
        throw PackagingError("Refusing to replace a non-directory or symlink at \(path).")
    }
    return true
}

func requireStopped(_ app: String) throws {
    _ = try isDirectoryIfPresent(app)
    let executable = URL(fileURLWithPath: app).appendingPathComponent("Contents/MacOS/Zipper")
        .resolvingSymlinksInPath().path
    // Inspect kernel executable paths, which also catches launches directly from
    // Terminal that are absent from NSWorkspace's application list.
    var capacity = Int(proc_listallpids(nil, 0)) + 128
    while true {
        guard capacity > 128, capacity < 1_000_000 else {
            throw PackagingError("Could not enumerate processes to check whether Zipper is running.")
        }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw PackagingError("Could not enumerate running processes.") }
        if Int(count) >= capacity { capacity *= 2; continue }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            if length > 0 && URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == executable {
                throw PackagingError("Zipper is running (PID \(pid)). Quit it before rebuilding; an active handoff must finish or cancel first.")
            }
        }
        return
    }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else { throw PackagingError("Expected check APP or publish STAGED_APP APP.") }
    if arguments[1] == "check" && arguments.count == 3 {
        try requireStopped(arguments[2])
    } else if arguments[1] == "publish" && arguments.count == 4 {
        let staged = arguments[2]
        let app = arguments[3]
        guard try isDirectoryIfPresent(staged) else { throw PackagingError("Staged application is missing.") }
        try requireStopped(app)
        let exists = try isDirectoryIfPresent(app)
        // There is no remove/rename gap and no in-place executable overwrite.
        // If atomic swapping is unsupported, fail with the old bundle intact.
        let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renamex_np(staged, app, flags) == 0 else {
            throw PackagingError("Could not atomically publish Zipper: \(String(cString: strerror(errno))). Previous application was preserved.")
        }
    } else {
        throw PackagingError("Expected check APP or publish STAGED_APP APP.")
    }
} catch {
    fputs("Packaging failed: \(error)\n", stderr)
    exit(1)
}
