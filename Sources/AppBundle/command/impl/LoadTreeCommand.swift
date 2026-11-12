import Common
import Foundation

private let maxLoadTreeFileSize: Int64 = 10 * 1024 * 1024

struct LoadTreeCommand: Command {
    let args: LoadTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let path = args.path.val
        guard path.hasPrefix("/") else {
            return .fail(io.err("load-tree: path must be absolute: '\(path)'"))
        }
        // The server reads the file on the main actor: never touch FIFOs, devices or huge files
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) else {
            return .fail(io.err("load-tree: can't read '\(path)': no such file"))
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            return .fail(io.err("load-tree: '\(path)' is not a regular file"))
        }
        guard let size = (attrs[.size] as? NSNumber)?.int64Value, size <= maxLoadTreeFileSize else {
            return .fail(io.err("load-tree: '\(path)': file is larger than 10 MB"))
        }
        let json: String
        do {
            json = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return .fail(io.err("load-tree: can't read '\(path)': \(error.localizedDescription)"))
        }
        switch parseTreeSnapshot(json) {
            case .failure(let msg):
                return .fail(io.err("load-tree: \(msg)"))
            case .success(let workspaces):
                let result = applyTreeSnapshot(workspaces)
                return .succ(io.out(result.skippedWindowIds.map { "skipped: \($0)" }))
        }
    }
}
