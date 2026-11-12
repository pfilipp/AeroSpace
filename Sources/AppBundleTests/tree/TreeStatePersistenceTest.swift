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
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        assertTrue(b.focusWorkspace())
        assertEquals(mainMonitorInfo.activeWorkspace.name, "b")
        try await saveState()
        assertTrue(a.focusWorkspace()) // `a` is empty: nothing focused
        assertEquals(mainMonitorInfo.activeWorkspace.name, "a")
        XCTAssertNil(focus.windowOrNil)

        XCTAssertTrue(restoreTreeStateAtLaunch())
        assertEquals(mainMonitorInfo.activeWorkspace.name, "b")
        assertEquals(focus.workspace.name, "b")
        XCTAssertTrue(focus.workspace.isVisible)
    }

    func testFocusFollowsRestoredWindow() async throws {
        let a = Workspace.get(byName: "a")
        let window1 = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: a.rootTilingContainer)
        assertTrue(window1.focusWindow())
        try await saveState()
        // Startup registers the focused window into its monitor's stub workspace
        let stub = Workspace.get(byName: "stub")
        window1.bind(to: stub.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertTrue(window1.focusWindow())
        assertEquals(focus.workspace.name, "stub")

        XCTAssertTrue(restoreTreeStateAtLaunch())
        assertEquals(focus.workspace.name, "a")
        XCTAssertTrue(a.isVisible)
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testFocusFallsBackToVisibleWorkspace() async throws {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        assertTrue(b.focusWorkspace())
        try await saveState()
        let stub = Workspace.get(byName: "stub")
        assertTrue(stub.focusWorkspace()) // No focused window, and the restore hides `stub`
        XCTAssertNil(focus.windowOrNil)

        XCTAssertTrue(restoreTreeStateAtLaunch())
        XCTAssertFalse(stub.isVisible)
        assertEquals(focus.workspace.name, "b")
        XCTAssertTrue(focus.workspace.isVisible)
    }

    func testFocusedWindowOutsideSavedStateKeepsFocusVisible() async throws {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        assertTrue(b.focusWorkspace())
        try await saveState()
        let window3 = TestWindow.new(id: 3, parent: Workspace.get(byName: "c").rootTilingContainer)
        assertTrue(window3.focusWindow())
        assertEquals(focus.workspace.name, "c")

        XCTAssertTrue(restoreTreeStateAtLaunch())
        XCTAssertTrue(focus.workspace.isVisible)
        assertEquals(focus.windowOrNil?.windowId, 3)
    }

    func testFirstWriteRotatesWhenLaunchDidNot() async throws {
        let windows = buildTree()
        let oldJson = await encodeCurrentTreeState(now: 50)
        try writeCurrentTreeState(oldJson)
        config.persistTreeState = false // e.g. the config failed to parse at launch
        XCTAssertFalse(restoreTreeStateAtLaunch())
        XCTAssertTrue(exists("current.json"))
        XCTAssertTrue(previousNames().isEmpty)

        config.persistTreeState = true // reload-config
        flatten(Workspace.get(byName: "a"), [windows[3]!, windows[2]!, windows[1]!])
        await persistTreeStateIfChanged()

        assertEquals(previousNames(), ["50.json"])
        assertEquals(try String(contentsOf: dir.appendingPathComponent("previous/50.json"), encoding: .utf8), oldJson)
        let state = try XCTUnwrap(rotateTreeStateAtLaunch())
        assertEquals(windowIds(of: state, workspace: "a"), [3, 2, 1])
    }

    func testNoWritesAfterPowerOffNotice() async throws {
        treeStateWriteThrottleInterval = 60
        let windows = buildTree()
        XCTAssertFalse(restoreTreeStateAtLaunch())
        await persistTreeStateIfChanged()
        let written = try Data(contentsOf: currentFile)
        let a = Workspace.get(byName: "a")
        flatten(a, [windows[3]!, windows[2]!, windows[1]!])
        await persistTreeStateIfChanged()
        XCTAssertTrue(isTreeStateDeferredWritePending)

        treeStatePersistenceWillPowerOff()
        XCTAssertFalse(isTreeStateDeferredWritePending)
        treeStateWriteThrottleInterval = 0
        flatten(a, [windows[2]!, windows[1]!, windows[3]!])
        await persistTreeStateIfChanged()
        XCTAssertFalse(isTreeStateDeferredWritePending)
        assertEquals(try Data(contentsOf: currentFile), written)
    }

    func testTornDumpIsNotWritten() async throws {
        treeStateWriteThrottleInterval = 0.05
        let a = Workspace.get(byName: "a")
        var window2: Window!
        let hook = TitleReadHookWindow(id: 1, parent: a.rootTilingContainer)
        a.rootTilingContainer.apply { window2 = TestWindow.new(id: 2, parent: $0) }
        XCTAssertFalse(restoreTreeStateAtLaunch())
        // The tree changes while the encode is suspended reading a title
        hook.onTitleRead = { window2.bind(to: a.rootTilingContainer, adaptiveWeight: 1, index: 0) }

        await persistTreeStateIfChanged()
        XCTAssertFalse(exists("current.json"))
        XCTAssertTrue(isTreeStateDeferredWritePending)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(isTreeStateDeferredWritePending)
        let state = try XCTUnwrap(rotateTreeStateAtLaunch())
        assertEquals(windowIds(of: state, workspace: "a"), [2, 1])
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
        assertEquals(windowIds(of: state, workspace: "a"), [2, 1, 3])
    }

    /// IDs of the root's direct window children
    private func windowIds(of state: PersistedTreeState, workspace: String) -> [UInt32?] {
        (state.workspaces.first { $0.name == workspace }?.root.children ?? []).map { child -> UInt32? in
            if case .window(let w) = child { w.windowId } else { nil }
        }
    }
}

/// Runs `onTitleRead` once, inside the encode's title read, to change the tree mid-dump
private final class TitleReadHookWindow: Window {
    nonisolated(unsafe) var onTitleRead: (@MainActor () -> Void)?

    @MainActor
    init(id: UInt32, parent: NonLeafTreeNodeObject) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String {
        if let hook = unsafe onTitleRead {
            unsafe onTitleRead = nil
            await hook()
        }
        return "hook"
    }
}
