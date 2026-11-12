@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TreeCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        assertNotNil(parseCommand("tree").cmdOrNil)
        assertNotNil(parseCommand("tree --json").cmdOrNil)
        assertNotNil(parseCommand("tree --workspace a").cmdOrNil)
        assertNotNil(parseCommand("tree --focused").cmdOrNil)
        assertNotNil(parseCommand("tree --json --floating-windows-as-tiling-windows --focused").cmdOrNil)
        assertEquals(parseCommand("tree --workspace a --focused").errorOrNil, "ERROR: Conflicting flags: --focused, --workspace")
    }

    @Test func testJsonNestedTree() async throws {
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

        let workspaces = try await runJson("tree --json --workspace a")
        assertEquals(workspaces.count, 1)
        let ws = workspaces[0]
        assertEquals(ws["type"] as? String, "workspace")
        assertEquals(ws["name"] as? String, "a")
        assertEquals(ws["is-focused"] as? Bool, false)
        assertEquals(ws["monitor"] as? String, "Test Monitor")

        let root = try #require(ws["root-container"] as? [String: Any])
        assertEquals(root["type"] as? String, "container")
        assertEquals(root["layout"] as? String, "h_tiles")
        assertEquals(root["orientation"] as? String, "horizontal")
        let rootChildren = try #require(root["children"] as? [[String: Any]])
        assertEquals(rootChildren.map { $0["type"] as? String }, ["window", "container"])
        assertEquals(rootChildren[0]["window-id"] as? Int, 1)
        assertEquals(rootChildren[0]["app-bundle-id"] as? String, "bobko.AeroSpace.test-app")
        assertEquals(rootChildren[0]["title"] as? String, "TestWindow(1)")

        let nested = rootChildren[1]
        assertEquals(nested["layout"] as? String, "v_tiles")
        assertEquals(nested["orientation"] as? String, "vertical")
        let nestedChildren = try #require(nested["children"] as? [[String: Any]])
        assertEquals(nestedChildren.map { $0["window-id"] as? Int }, [2, 3])

        let floating = try #require(ws["floating-windows"] as? [[String: Any]])
        assertEquals(floating.map { $0["window-id"] as? Int }, [4])
        assertEquals((ws["macos-fullscreen-windows"] as? [Any])?.count, 0)
    }

    @Test func testJsonFloatingWindowsAsTilingWindows() async throws {
        Workspace.get(byName: "a").apply {
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
            TestWindow.new(id: 2, parent: $0.floatingWindowsContainer)
        }

        let workspaces = try await runJson("tree --json --floating-windows-as-tiling-windows --workspace a")
        let ws = try #require(workspaces.singleOrNil())
        assertNil(ws["floating-windows"])
        let root = try #require(ws["root-container"] as? [String: Any])
        let rootChildren = try #require(root["children"] as? [[String: Any]])
        assertEquals(rootChildren.map { $0["window-id"] as? Int }, [1, 2])
    }

    @Test func testJsonFocusedWindow() async throws {
        let workspace = Workspace.get(byName: "a").apply {
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
            assertEquals(TestWindow.new(id: 2, parent: $0.rootTilingContainer).focusWindow(), true)
        }
        assertEquals(workspace.focusWorkspace(), true)

        let workspaces = try await runJson("tree --json --focused")
        let ws = try #require(workspaces.singleOrNil())
        assertEquals(ws["name"] as? String, "a")
        assertEquals(ws["is-focused"] as? Bool, true)
        assertEquals(ws["is-visible"] as? Bool, true)
        let root = try #require(ws["root-container"] as? [String: Any])
        let rootChildren = try #require(root["children"] as? [[String: Any]])
        assertEquals(rootChildren.map { $0["is-focused"] as? Bool }, [false, true])
    }

    @Test func testWorkspaceFilter() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)

        let all = try await runJson("tree --json")
        assertEquals(all.map { $0["name"] as? String }, ["a", "b", "setUpWorkspacesForTests"])

        let filtered = try await runJson("tree --json --workspace b")
        assertEquals(filtered.map { $0["name"] as? String }, ["b"])
        let root = try #require(filtered[0]["root-container"] as? [String: Any])
        let rootChildren = try #require(root["children"] as? [[String: Any]])
        assertEquals(rootChildren.map { $0["window-id"] as? Int }, [2])
    }

    @Test func testText() async {
        var focused: Window? = nil
        Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    focused = TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            TestWindow.new(id: 4, parent: $0.floatingWindowsContainer)
        }
        assertEquals(focused?.focusWindow(), true)

        let result = await parseCommand("tree --workspace a").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false), [
            "Workspace \"a\" (focused, visible, monitor: \"Test Monitor\")",
            "├── [h_tiles]",
            "│   ├── [1] bobko.AeroSpace.test-app — \"TestWindow(1)\"",
            "│   └── [v_tiles]",
            "│       ├── [2] bobko.AeroSpace.test-app — \"TestWindow(2)\" *",
            "│       └── [3] bobko.AeroSpace.test-app — \"TestWindow(3)\"",
            "└── Floating:",
            "    └── [4] bobko.AeroSpace.test-app — \"TestWindow(4)\"",
        ])
    }

    @Test func testTextFloatingAndMacosFullscreenSections() async {
        Workspace.get(byName: "a").apply {
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
            TestWindow.new(id: 2, parent: $0.floatingWindowsContainer)
            TestWindow.new(id: 3, parent: $0.macOsNativeFullscreenWindowsContainer)
        }

        let result = await parseCommand("tree --workspace a").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false), [
            "Workspace \"a\" (monitor: \"Test Monitor\")",
            "├── [h_tiles]",
            "│   └── [1] bobko.AeroSpace.test-app — \"TestWindow(1)\"",
            "├── Floating:",
            "│   └── [2] bobko.AeroSpace.test-app — \"TestWindow(2)\"",
            "└── Fullscreen:",
            "    └── [3] bobko.AeroSpace.test-app — \"TestWindow(3)\"",
        ])
    }

    @Test func testTextFloatingWindowsAsTilingWindows() async {
        Workspace.get(byName: "a").apply {
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
            TestWindow.new(id: 2, parent: $0.floatingWindowsContainer)
        }

        let result = await parseCommand("tree --workspace a --floating-windows-as-tiling-windows").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false), [
            "Workspace \"a\" (monitor: \"Test Monitor\")",
            "└── [h_tiles]",
            "    ├── [1] bobko.AeroSpace.test-app — \"TestWindow(1)\"",
            "    └── [2] bobko.AeroSpace.test-app — \"TestWindow(2)\" (floating)",
        ])
    }

    private func runJson(_ command: String) async throws -> [[String: Any]] {
        let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        let json = try #require(result.stdout.singleOrNil())
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }
}
