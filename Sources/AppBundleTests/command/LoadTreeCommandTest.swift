@testable import AppBundle
import Common
import XCTest

@MainActor
final class LoadTreeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        let cmd = parseCommand(["load-tree", "/tmp/x.json"]).cmdOrDie
        assertEquals((cmd as? LoadTreeCommand)?.args.path.val, "/tmp/x.json")
        assertEquals(cmd.shouldResetClosedWindowsCache, true)
        testParseCommandFail("load-tree", msg: "ERROR: Argument '<absolute-path>' is mandatory", exitCode: 2)
    }

    func testAppliesFile() async throws {
        let workspace = Workspace.get(byName: "a")
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let path = try writeSnapshot(#"[{"name": "a", "root-container": {"type": "container", "layout": "v_tiles", "orientation": "vertical", "children": [{"type": "window", "window-id": 2}, {"type": "window", "window-id": 1}]}}]"#)
        let result = await parseCommand("load-tree \(path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, [])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .window(1)]))
    }

    func testReportsSkipped() async throws {
        Workspace.get(byName: "a").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }
        let path = try writeSnapshot(#"[{"name": "a", "root-container": {"type": "container", "layout": "h_tiles", "orientation": "horizontal", "children": [{"type": "window", "window-id": 1}, {"type": "window", "window-id": 99}]}}]"#)
        let result = await parseCommand("load-tree \(path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["skipped: 99"])
    }

    func testFailLeavesTreeUntouched() async throws {
        let root = Workspace.get(byName: "a").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let path = try writeSnapshot(#"[{"name": "a", "root-container": {"type": "container", "layout": "spiral", "orientation": "horizontal", "children": [{"type": "window", "window-id": 2}, {"type": "window", "window-id": 1}]}}]"#)
        let result = await parseCommand("load-tree \(path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr.isEmpty, false)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testRejectsRelativePath() async {
        let result = await parseCommand("load-tree x.json").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr.isEmpty, false)
    }

    func testMissingFile() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("load-tree-missing-\(UUID().uuidString).json").path
        let result = await parseCommand("load-tree \(path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr.isEmpty, false)
    }

    func testRejectsDirectory() async {
        let root = Workspace.get(byName: "a").rootTilingContainer.apply { TestWindow.new(id: 1, parent: $0) }
        let result = await parseCommand("load-tree \(FileManager.default.temporaryDirectory.path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr.joined().contains("not a regular file"), true)
        assertEquals(root.layoutDescription, .h_tiles([.window(1)]))
    }

    func testRejectsDeviceFile() async {
        let result = await parseCommand("load-tree /dev/null").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr.joined().contains("not a regular file"), true)
    }

    func testRejectsOversizedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("load-tree-big-\(UUID().uuidString).json")
        try Data(count: 10 * 1024 * 1024 + 1).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = await parseCommand("load-tree \(url.path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr.joined().contains("larger than 10 MB"), true)
    }

    func testAcceptsSymlinkToRegularFile() async throws {
        let workspace = Workspace.get(byName: "a")
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let target = try writeSnapshot(#"[{"name": "a", "root-container": {"type": "container", "layout": "v_tiles", "orientation": "vertical", "children": [{"type": "window", "window-id": 2}, {"type": "window", "window-id": 1}]}}]"#)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("load-tree-link-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        let result = await parseCommand("load-tree \(link.path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .window(1)]))
    }

    private func writeSnapshot(_ json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("load-tree-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
