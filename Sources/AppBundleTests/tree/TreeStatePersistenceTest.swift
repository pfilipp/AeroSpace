@testable import AppBundle
import Common
import XCTest

@MainActor
final class TreeStatePersistenceTest: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetTreeStatePersistenceForTests()
        config.persistTreeState = true
        treeStateWriteThrottleInterval = 0
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-persist-test-\(UUID().uuidString)")
        treeStateDirOverride = dir
        bootSessionOverride = "BOOT-A"
    }

    override func tearDown() async throws {
        resetTreeStatePersistenceForTests()
        treeStateDirOverride = nil
        bootSessionOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private var currentFile: URL { dir.appendingPathComponent("current.json") }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    private func previousNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("previous").path)) ?? []).sorted()
    }

    @discardableResult
    private func buildTree(extraWindowId: UInt32? = nil) -> [UInt32: Window] {
        var windows: [UInt32: Window] = [:]
        Workspace.get(byName: "a").rootTilingContainer.apply {
            windows[1] = TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                windows[2] = TestWindow.new(id: 2, parent: $0)
                windows[3] = TestWindow.new(id: 3, parent: $0)
                if let extraWindowId { windows[extraWindowId] = TestWindow.new(id: extraWindowId, parent: $0) }
            }
        }
        return windows
    }

    /// Simulates the pile-up after a restart: every window flat in the root, in the given order
    private func flatten(_ workspace: Workspace, _ windows: [Window]) {
        workspace.rootTilingContainer.unbindFromParent()
        let root = workspace.rootTilingContainer
        for window in windows { window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
    }

    private func saveState() async throws {
        try writeCurrentTreeState(await encodeCurrentTreeState(now: 100))
    }

    func testSameBootIsApplied() async throws {
        let windows = buildTree()
        try await saveState()
        let a = Workspace.get(byName: "a")
        flatten(a, [windows[3]!, windows[2]!, windows[1]!])
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))

        XCTAssertTrue(restoreTreeStateAtLaunch())
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    func testDifferentBootIsRotatedNotApplied() async throws {
        let windows = buildTree()
        try await saveState()
        let a = Workspace.get(byName: "a")
        flatten(a, [windows[3]!, windows[2]!, windows[1]!])
        bootSessionOverride = "BOOT-B"

        XCTAssertFalse(restoreTreeStateAtLaunch())
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        XCTAssertFalse(exists("current.json"))
        assertEquals(previousNames(), ["100.json"])
    }

    func testEmptyBootSessionIsNotApplied() async throws {
        let windows = buildTree()
        try await saveState()
        let a = Workspace.get(byName: "a")
        flatten(a, [windows[3]!, windows[2]!, windows[1]!])
        bootSessionOverride = ""

        XCTAssertFalse(restoreTreeStateAtLaunch())
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        assertEquals(previousNames(), ["100.json"])
    }

    func testOptionOffDoesNothing() async throws {
        buildTree()
        try await saveState()
        config.persistTreeState = false

        XCTAssertFalse(restoreTreeStateAtLaunch())
        XCTAssertTrue(exists("current.json"))
        XCTAssertTrue(previousNames().isEmpty)

        try FileManager.default.removeItem(at: dir)
        await persistTreeStateIfChanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testNoWriteBeforeLaunchRestore() async throws {
        buildTree()
        await persistTreeStateIfChanged()
        XCTAssertFalse(exists("current.json"))
    }

    func testWritesOnChangeOnly() async throws {
        buildTree()
        XCTAssertFalse(restoreTreeStateAtLaunch())
        await persistTreeStateIfChanged()
        XCTAssertTrue(exists("current.json"))
        let date = try FileManager.default.attributesOfItem(atPath: currentFile.path)[.modificationDate] as? Date
        XCTAssertNotNil(date)

        try await Task.sleep(for: .milliseconds(20))
        await persistTreeStateIfChanged()
        assertEquals(try FileManager.default.attributesOfItem(atPath: currentFile.path)[.modificationDate] as? Date, date)
    }

    func testMissingWindowAtLaunch() async throws {
        let windows = buildTree(extraWindowId: 9)
        try await saveState()
        let a = Workspace.get(byName: "a")
        windows[9]!.unbindFromParent()
        flatten(a, [windows[3]!, windows[2]!, windows[1]!])

        XCTAssertTrue(restoreTreeStateAtLaunch())
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    func testWriteFailureDoesNotThrow() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let regularFile = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: regularFile)
        treeStateDirOverride = regularFile.appendingPathComponent("state")
        buildTree()
        XCTAssertFalse(restoreTreeStateAtLaunch())

        await persistTreeStateIfChanged()
        await persistTreeStateIfChanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: regularFile.appendingPathComponent("state").path))
    }

    func testRestoresVisibleWorkspace() async throws {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        assertTrue(b.focusWorkspace())
        assertEquals(mainMonitorInfo.activeWorkspace.name, "b")
        try await saveState()
        assertTrue(a.focusWorkspace())
        assertEquals(mainMonitorInfo.activeWorkspace.name, "a")

        XCTAssertTrue(restoreTreeStateAtLaunch())
        assertEquals(mainMonitorInfo.activeWorkspace.name, "b")
    }

    func testDeferredWriteCoalesces() async throws {
        treeStateWriteThrottleInterval = 0.05
        let windows = buildTree()
        XCTAssertFalse(restoreTreeStateAtLaunch())
        await persistTreeStateIfChanged() // first write is immediate
        XCTAssertTrue(exists("current.json"))
        assertEquals(treeStateDeferredWritesScheduled, 0)

        let a = Workspace.get(byName: "a")
        flatten(a, [windows[3]!, windows[2]!, windows[1]!])
        await persistTreeStateIfChanged()
        flatten(a, [windows[2]!, windows[1]!, windows[3]!])
        await persistTreeStateIfChanged()
        assertEquals(treeStateDeferredWritesScheduled, 1)

        try await Task.sleep(for: .milliseconds(300))
        assertEquals(treeStateDeferredWritesScheduled, 1)
        let state = try XCTUnwrap(rotateTreeStateAtLaunch())
        let saved = try XCTUnwrap(state.workspaces.first { $0.name == "a" })
        assertEquals(saved.root.children.map { child -> UInt32? in
            if case .window(let w) = child { w.windowId } else { nil }
        }, [2, 1, 3])
    }
}
