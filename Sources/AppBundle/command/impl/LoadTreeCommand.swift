import Common
import Foundation

struct LoadTreeCommand: Command {
    let args: LoadTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let path = args.path.val
        guard path.hasPrefix("/") else {
            return .fail(io.err("load-tree: path must be absolute: '\(path)'"))
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
