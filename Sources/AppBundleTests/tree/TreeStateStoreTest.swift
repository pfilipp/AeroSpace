@testable import AppBundle
import Common
import XCTest

@MainActor
final class TreeStateStoreTest: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-state-test-\(UUID().uuidString)")
        treeStateDirOverride = dir
        bootTimeOverride = 1000
    }

    override func tearDown() async throws {
        treeStateDirOverride = nil
        bootTimeOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    private func previousNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("previous").path)) ?? []).sorted()
    }

    private func buildTree() {
        Workspace.get(byName: "a").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
    }

    func testWriteThenRotateRoundTrip() async throws {
        buildTree()
        try writeCurrentTreeState(await encodeCurrentTreeState(now: 50))
        let state = try XCTUnwrap(rotateTreeStateAtLaunch())
        assertEquals(state.bootTime, 1000)
        assertEquals(state.writtenAt, 50)
        let expected = TreeSnapshotWorkspace(
            name: "a",
            root: TreeSnapshotContainer(layout: .tiles, orientation: .h, weight: nil, children: [
                .window(TreeSnapshotWindow(windowId: 1, weight: 1)),
                .container(TreeSnapshotContainer(layout: .tiles, orientation: .v, weight: 1, children: [
                    .window(TreeSnapshotWindow(windowId: 2, weight: 1)),
                    .window(TreeSnapshotWindow(windowId: 3, weight: 1)),
                ])),
            ]),
            floatingWindows: [],
        )
        assertEquals(state.workspaces.first { $0.name == "a" }, expected)
        XCTAssertFalse(exists("current.json"))
        XCTAssertTrue(exists("previous/50.json"))
    }

    func testEnvelopeShape() async throws {
        buildTree()
        let json = await encodeCurrentTreeState(now: 7)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        assertEquals(Set(obj.keys), ["version", "boot-time", "written-at", "visible-workspaces", "workspaces"])
        assertEquals(obj["version"] as? Int, 1)
        assertEquals(obj["boot-time"] as? Int, 1000)
        assertEquals(obj["written-at"] as? Int, 7)
        let workspaces = try XCTUnwrap(obj["workspaces"] as? [[String: Any]])
        let a = try XCTUnwrap(workspaces.first { $0["name"] as? String == "a" })
        let root = try XCTUnwrap(a["root-container"] as? [String: Any])
        let window = try XCTUnwrap((root["children"] as? [[String: Any]])?.first)
        XCTAssertNotNil(window["window-id"])
        XCTAssertNotNil(window["app-bundle-id"])
        XCTAssertNotNil(window["title"])
    }

    func testKeepsFivePrevious() async throws {
        buildTree()
        for now in 1 ... 7 {
            try writeCurrentTreeState(await encodeCurrentTreeState(now: now))
            _ = rotateTreeStateAtLaunch()
        }
        assertEquals(previousNames(), ["3.json", "4.json", "5.json", "6.json", "7.json"])
    }

    func testPruneOrdersNumerically() async throws {
        buildTree()
        for now in 8 ... 13 {
            try writeCurrentTreeState(await encodeCurrentTreeState(now: now))
            _ = rotateTreeStateAtLaunch()
        }
        assertEquals(previousNames(), ["10.json", "11.json", "12.json", "13.json", "9.json"])
    }

    func testRotateSameSecondDoesNotThrow() async throws {
        buildTree()
        for _ in 1 ... 2 {
            try writeCurrentTreeState(await encodeCurrentTreeState(now: 5))
            XCTAssertNotNil(rotateTreeStateAtLaunch())
        }
        assertEquals(previousNames(), ["5.json"])
    }

    func testCorruptCurrentIsIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("current.json"))
        XCTAssertNil(rotateTreeStateAtLaunch())
        XCTAssertFalse(exists("current.json"))
        assertEquals(previousNames().count, 1)
    }

    func testNoCurrentFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(rotateTreeStateAtLaunch())
    }

    func testSignatureIgnoresFocusButSeesStructure() {
        var w2: TestWindow!
        var other: TilingContainer!
        let root = Workspace.get(byName: "a").rootTilingContainer
        root.apply {
            TestWindow.new(id: 1, parent: $0)
            w2 = TestWindow.new(id: 2, parent: $0)
            other = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1)
        }
        let before = treeStructureSignature()
        _ = w2.focusWindow()
        assertEquals(treeStructureSignature(), before)
        _ = w2.bind(to: other, adaptiveWeight: 1, index: 0)
        let moved = treeStructureSignature()
        XCTAssertNotEqual(moved, before)
        w2.setWeight(.v, 5)
        XCTAssertNotEqual(treeStructureSignature(), moved)
    }

    func testStateDirRule() {
        let home = URL(fileURLWithPath: "/h")
        assertEquals(resolveTreeStateDir(env: ["XDG_STATE_HOME": "/x/state"], home: home).path, "/x/state/aerospace")
        assertEquals(resolveTreeStateDir(env: [:], home: home).path, "/h/.local/state/aerospace")
        assertEquals(resolveTreeStateDir(env: ["XDG_STATE_HOME": ""], home: home).path, "/h/.local/state/aerospace")
    }
}
