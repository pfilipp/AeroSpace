@testable import AppBundle
import Common
import XCTest

@MainActor
final class TreeSnapshotTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func treeJson(_ workspace: String) async -> String {
        let result = await parseCommand("tree --json --workspace \(workspace)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        return result.stdout.joined(separator: "\n")
    }

    func testTreeJsonCarriesWeights() async throws {
        Workspace.get(byName: "a").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
        }
        let json = await treeJson("a")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let workspaces = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let root = try XCTUnwrap(workspaces.first?["root-container"] as? [String: Any])
        XCTAssertNil(root["weight"])
        let children = try XCTUnwrap(root["children"] as? [[String: Any]])
        assertEquals(children.map { $0["weight"] as? Double }, [2, 1])
    }

    func testParseRoundTrip() async {
        Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            TestWindow.new(id: 4, parent: $0.floatingWindowsContainer)
        }
        let json = await treeJson("a")
        let expected = TreeSnapshotWorkspace(
            name: "a",
            root: TreeSnapshotContainer(layout: .tiles, orientation: .h, weight: nil, children: [
                .window(TreeSnapshotWindow(windowId: 1, weight: 1)),
                .container(TreeSnapshotContainer(layout: .tiles, orientation: .v, weight: 1, children: [
                    .window(TreeSnapshotWindow(windowId: 2, weight: 1)),
                    .window(TreeSnapshotWindow(windowId: 3, weight: 1)),
                ])),
            ]),
            floatingWindows: [TreeSnapshotWindow(windowId: 4, weight: nil)],
        )
        XCTAssertEqual(parseTreeSnapshot(json), .success([expected]))
    }

    func testParseIgnoresUnknownKeys() {
        let json = """
            [{"name": "a", "startup": true, "monitor": "m",
              "root-container": {"layout": "h_tiles", "orientation": "horizontal", "children": [
                {"window-id": 1, "title": "t", "weight": 3}
              ]}}]
            """
        guard case .success(let ws) = parseTreeSnapshot(json) else { return XCTFail() }
        assertEquals(ws.count, 1)
        assertEquals(ws[0].root.children, [.window(TreeSnapshotWindow(windowId: 1, weight: 3))])
        assertEquals(ws[0].floatingWindows, [])
    }

    func testParseRejectsUnknownLayout() {
        let json = #"[{"name": "a", "root-container": {"layout": "spiral", "children": []}}]"#
        guard case .failure(let msg) = parseTreeSnapshot(json) else { return XCTFail() }
        XCTAssertTrue(msg.contains("spiral"), msg)
    }

    func testRejectsDuplicateWindowId() {
        let json = """
            [{"name": "a", "root-container": {"layout": "h_tiles", "children": [{"window-id": 7}]},
              "floating-windows": [{"window-id": 7}]}]
            """
        guard case .failure(let msg) = parseTreeSnapshot(json) else { return XCTFail() }
        XCTAssertTrue(msg.contains("7"), msg)
    }

    func testParseRejectsNonArray() {
        guard case .failure = parseTreeSnapshot("{}") else { return XCTFail() }
    }
}
