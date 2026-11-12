@testable import AppBundle
import Common
import XCTest

@MainActor
final class ApplyTreeSnapshotTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRebuildsNestedTree() {
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.accordion, .h, [win(1), .container(container(.tiles, .v, [win(3), win(2)]))])),
        ])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_accordion([.window(1), .v_tiles([.window(3), .window(2)])]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: []))
    }

    func testAppliesWeights() {
        var window1: Window!
        var window2: Window!
        Workspace.get(byName: "a").rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
        }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(1, weight: 3), win(2, weight: 1)]))])
        assertEquals(window1.getWeight(.h), 3)
        assertEquals(window2.getWeight(.h), 1)
    }

    func testSkipsMissingWindowKeepsRest() {
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .h, [win(1), win(99), .container(container(.tiles, .v, [win(2), win(98), win(3)]))])),
        ])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: [98, 99]))
    }

    func testDropsEmptyContainer() {
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(1), .container(container(.tiles, .v, [win(99)]))]))])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testUnmentionedWindowsStay() {
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(3), win(1)]))])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(1), .window(2)]))
    }

    func testMovesAcrossWorkspaces() {
        let a = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        let b = Workspace.get(byName: "b").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 5, parent: $0)
            }
        }
        let c = Workspace.get(byName: "c").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 6, parent: $0)
            }
        }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(1), win(5)]))])
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(5)]))
        assertEquals(b.rootTilingContainer.layoutDescription, .h_tiles([]))
        assertEquals(c.rootTilingContainer.layoutDescription, .h_tiles([.window(6)]))
    }

    func testFloating() {
        var window2: Window!
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                window2 = TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 8, parent: $0.floatingWindowsContainer)
        }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(1)]), floating: [TreeSnapshotWindow(windowId: 2, weight: nil)])])
        XCTAssertTrue(window2.parent === workspace.floatingWindowsContainer)
        assertEquals(workspace.floatingWindows.map(\.windowId).sorted(), [2, 8])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testTiledWindowBecomesTiledFromFloating() {
        var window4: Window!
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
            }
            window4 = TestWindow.new(id: 4, parent: $0.floatingWindowsContainer)
        }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(4), win(1)]))])
        XCTAssertTrue(window4.parent === workspace.rootTilingContainer)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(4), .window(1)]))
        assertEquals(workspace.floatingWindows.count, 0)
    }

    // MARK: edge cases beyond the brief

    func testWindowNamedUnderTwoWorkspacesFirstOccurrenceWins() {
        let a = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        let b = Workspace.get(byName: "b")
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .h, [win(1)])),
            snapshotWorkspace("b", container(.tiles, .h, [win(1), win(2)]), floating: [TreeSnapshotWindow(windowId: 1, weight: nil)]),
        ])
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(b.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
        assertEquals(b.floatingWindows.count, 0)
        assertEquals(Workspace.all.flatMap(\.allLeafWindowsRecursive).filter { $0.windowId == 1 }.count, 1)
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: []))
    }

    func testSameWorkspaceNamedTwiceFirstEntryWins() {
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        _ = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .h, [win(2), win(1)])),
            snapshotWorkspace("a", container(.accordion, .v, [win(1)])),
        ])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    func testAllWindowsMissingKeepsPreviouslyTiledWindows() {
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
        }
        let result = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .v, [win(99), .container(container(.tiles, .h, [win(98)]))]))])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .window(2)]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: [98, 99]))
    }

    func testSkippedIdsAreUniqueAndAscending() {
        Workspace.get(byName: "a").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .h, [win(99), win(1)]), floating: [TreeSnapshotWindow(windowId: 50, weight: nil)]),
            snapshotWorkspace("b", container(.tiles, .h, [win(99), win(97)])),
        ])
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: [50, 97, 99]))
    }

    func testOldRootWindowsClaimedByLaterWorkspaceAreMoved() {
        let a = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
        }
        let b = Workspace.get(byName: "b")
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .h, [win(1)])),
            snapshotWorkspace("b", container(.tiles, .h, [win(2)])),
        ])
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))
        assertEquals(b.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: []))
        for window in Workspace.all.flatMap(\.allLeafWindowsRecursive) {
            XCTAssertNotNil(window.nodeWorkspace)
        }
    }

    func testFocusedWindowStaysFocusedAndMostRecent() {
        var window2: Window!
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                window2 = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        assertEquals(window2.focusWindow(), true)
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(3), .container(container(.tiles, .v, [win(2), win(1)]))]))])
        XCTAssertTrue(focus.windowOrNil === window2)
        XCTAssertTrue(focus.workspace === workspace)
        XCTAssertTrue(workspace.mostRecentWindowRecursive === window2)
    }

    func testFocusedWindowMovedAwayLeavesValidFocus() {
        var window1: Window!
        var window2: Window!
        let a = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                window1 = TestWindow.new(id: 1, parent: $0)
                window2 = TestWindow.new(id: 2, parent: $0)
            }
        }
        assertEquals(window1.focusWindow(), true)
        _ = applyTreeSnapshot([snapshotWorkspace("b", container(.tiles, .h, [win(1)]))])
        XCTAssertTrue(window1.nodeWorkspace === Workspace.get(byName: "b"))
        // The focus keeps its workspace and falls back to a window that is still there
        XCTAssertTrue(focus.workspace === a)
        XCTAssertTrue(focus.windowOrNil === window2)
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
    }

    // MARK: fix round 1

    func testSkipsFullscreenWindow() {
        var fullscreen: Window!
        var hidden: Window!
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
            }
            fullscreen = TestWindow.new(id: 2, parent: $0.macOsNativeFullscreenWindowsContainer)
            hidden = TestWindow.new(id: 3, parent: $0.macOsNativeHiddenAppsWindowsContainer)
        }
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .h, [win(2), win(1)]), floating: [TreeSnapshotWindow(windowId: 3, weight: nil)]),
        ])
        XCTAssertTrue(fullscreen.parent === workspace.macOsNativeFullscreenWindowsContainer)
        XCTAssertTrue(hidden.parent === workspace.macOsNativeHiddenAppsWindowsContainer)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: [2, 3]))
    }

    func testSkipsMinimizedWindow() {
        let minimized = TestWindow.new(id: 2, parent: macosMinimizedWindowsContainer)
        defer { minimized.unbindFromParent() } // setUpWorkspacesForTests doesn't clean the global container
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        let result = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(1), win(2)]))])
        XCTAssertTrue(minimized.parent === macosMinimizedWindowsContainer)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: [2]))
    }

    func testNonStandardLayoutReasonIsSkipped() {
        var tiledMacos: Window!
        var floatingMacos: Window!
        let workspace = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                tiledMacos = TestWindow.new(id: 2, parent: $0)
            }
            floatingMacos = TestWindow.new(id: 3, parent: $0.floatingWindowsContainer)
        }
        tiledMacos.layoutReason = .macos(prevParentKind: .tilingContainer)
        floatingMacos.layoutReason = .macos(prevParentKind: .floatingWindowsContainer)
        let result = applyTreeSnapshot([
            snapshotWorkspace("a", container(.tiles, .v, [win(3), .container(container(.tiles, .h, [win(2), win(1)]))])),
            snapshotWorkspace("b", container(.tiles, .h, [win(2)])),
        ])
        XCTAssertTrue(floatingMacos.parent === workspace.floatingWindowsContainer)
        // Not placed by the snapshot, so it stays a tiled window of the workspace it was in
        XCTAssertTrue(tiledMacos.nodeWorkspace === workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.h_tiles([.window(1)]), .window(2)]))
        assertEquals(Workspace.get(byName: "b").rootTilingContainer.layoutDescription, .h_tiles([]))
        assertEquals(result, TreeSnapshotApplyResult(skippedWindowIds: [2, 3]))
    }

    func testInvalidWeightFallsBackToAuto() {
        let expected = referenceWeights([WEIGHT_AUTO, 2, WEIGHT_AUTO, WEIGHT_AUTO, WEIGHT_AUTO, WEIGHT_AUTO])
        let root = Workspace.get(byName: "a").rootTilingContainer
        let windows = (1 ... 6).map { TestWindow.new(id: UInt32($0), parent: root) }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [
            win(1, weight: 0), win(2, weight: 2), win(3, weight: -5),
            win(4, weight: .nan), win(5, weight: .infinity), win(6, weight: WEIGHT_DOESNT_MATTER),
        ]))])
        assertEquals(windows.map { $0.getWeight(.h) }, expected)
    }

    func testWeightAutoWhenAbsent() {
        let expected = referenceWeights([1, 3, WEIGHT_AUTO])
        let root = Workspace.get(byName: "a").rootTilingContainer
        let windows = (1 ... 3).map { TestWindow.new(id: UInt32($0), parent: root) }
        _ = applyTreeSnapshot([snapshotWorkspace("a", container(.tiles, .h, [win(1, weight: 1), win(2, weight: 3), win(3)]))])
        assertEquals(windows.map { $0.getWeight(.h) }, expected)
        assertEquals(expected[2], 2) // sanity: the average of the siblings bound before it
    }

    /// Weights produced by binding windows with these adaptive weights, in order, into a fresh h_tiles container
    private func referenceWeights(_ weights: [CGFloat]) -> [CGFloat] {
        let root = Workspace.get(byName: "reference").rootTilingContainer
        let windows = weights.enumerated().map { TestWindow.new(id: UInt32(1000 + $0.offset), parent: root, adaptiveWeight: $0.element) }
        return windows.map { $0.getWeight(.h) }
    }
}

private func win(_ id: UInt32, weight: CGFloat? = nil) -> TreeSnapshotNode {
    .window(TreeSnapshotWindow(windowId: id, weight: weight))
}

private func container(_ layout: Layout, _ orientation: Orientation, _ children: [TreeSnapshotNode]) -> TreeSnapshotContainer {
    TreeSnapshotContainer(layout: layout, orientation: orientation, weight: nil, children: children)
}

private func snapshotWorkspace(_ name: String, _ root: TreeSnapshotContainer, floating: [TreeSnapshotWindow] = []) -> TreeSnapshotWorkspace {
    TreeSnapshotWorkspace(name: name, root: root, floatingWindows: floating)
}
