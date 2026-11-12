import AppKit
import Common

struct TreeSnapshotApplyResult: Equatable {
    /// Window IDs named in the snapshot that don't exist. Ascending, unique
    let skippedWindowIds: [UInt32]
}

/// Makes each named workspace match its snapshot. Looks windows up with `Window.get(byId:)`.
///
/// - A workspace not named is untouched. If a workspace is named more than once, only its first entry is applied
/// - A window ID named more than once is applied at its first occurrence only (workspaces in order, the tiling tree
///   depth-first, then the floating windows)
/// - Missing windows are skipped and reported. Containers left without windows are not created
/// - Windows that were tiled in a rebuilt workspace and are not named anywhere are appended to its new root
@MainActor func applyTreeSnapshot(_ workspaces: [TreeSnapshotWorkspace]) -> TreeSnapshotApplyResult {
    // Resolve every window before touching the tree: once a root is unbound, its windows are no longer reachable
    // from `Workspace.all` (which is what `Window.get(byId:)` scans in unit tests)
    var plan = SnapshotPlan()
    let plannedWorkspaces: [PlannedWorkspace] = workspaces.compactMap { snapshot in
        guard plan.claimedWorkspaceNames.insert(snapshot.name).inserted else { return nil }
        return PlannedWorkspace(
            workspace: Workspace.get(byName: snapshot.name),
            root: plan.resolve(snapshot.root),
            floatingWindows: snapshot.floatingWindows.compactMap { plan.resolve($0) },
        )
    }

    // Old roots are kept alive until the end: windows that a later workspace claims stay in them until then
    var prevRoots: [TilingContainer] = []
    var prevMruWindows: [(Workspace, Window)] = []
    for planned in plannedWorkspaces {
        let workspace = planned.workspace
        if let mru = workspace.mostRecentWindowRecursive { prevMruWindows.append((workspace, mru)) }
        let prevRoot = workspace.rootTilingContainer
        prevRoots.append(prevRoot)
        let prevTiledWindows = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()

        let newRoot = TilingContainer(parent: workspace, adaptiveWeight: 1, planned.root.orientation, planned.root.layout, index: INDEX_BIND_LAST)
        bindChildren(planned.root.children, to: newRoot)
        for window in prevTiledWindows where !plan.claimedWindowIds.contains(window.windowId) {
            window.bind(to: newRoot, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        for window in planned.floatingWindows {
            window.bindAsFloatingWindow(to: workspace)
        }
    }

    // Binding marks every bound node as the most recent child. Give each workspace back its most recent window, if
    // it's still there, so that focusing the workspace lands where it did before. Focus itself is stored by window ID
    // and workspace name, so it stays valid without any help
    for (workspace, window) in prevMruWindows where window.nodeWorkspace === workspace {
        window.markAsMostRecentChild()
    }
    if let focusedWindow = focus.windowOrNil, plannedWorkspaces.contains(where: { $0.workspace === focusedWindow.nodeWorkspace }) {
        focusedWindow.markAsMostRecentChild()
    }
    withExtendedLifetime(prevRoots) {}

    return TreeSnapshotApplyResult(skippedWindowIds: plan.skippedWindowIds.sorted())
}

private struct SnapshotPlan {
    var claimedWorkspaceNames: Set<String> = []
    var claimedWindowIds: Set<UInt32> = []
    var skippedWindowIds: Set<UInt32> = []

    /// Returns nil for a window that is missing or already claimed
    @MainActor mutating func resolve(_ snapshot: TreeSnapshotWindow) -> Window? {
        if claimedWindowIds.contains(snapshot.windowId) { return nil }
        guard let window = Window.get(byId: snapshot.windowId) else {
            skippedWindowIds.insert(snapshot.windowId)
            return nil
        }
        claimedWindowIds.insert(snapshot.windowId)
        return window
    }

    /// The returned container has no empty sub-containers. The root itself may be empty
    @MainActor mutating func resolve(_ snapshot: TreeSnapshotContainer) -> PlannedContainer {
        var children: [PlannedNode] = []
        for child in snapshot.children {
            switch child {
                case .window(let w):
                    if let window = resolve(w) { children.append(.window(window, weight: w.weight)) }
                case .container(let c):
                    let container = resolve(c)
                    if !container.children.isEmpty { children.append(.container(container)) }
            }
        }
        return PlannedContainer(layout: snapshot.layout, orientation: snapshot.orientation, weight: snapshot.weight, children: children)
    }
}

private struct PlannedWorkspace {
    let workspace: Workspace
    let root: PlannedContainer
    let floatingWindows: [Window]
}

private struct PlannedContainer {
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat?
    let children: [PlannedNode]
}

private indirect enum PlannedNode {
    case window(Window, weight: CGFloat?)
    case container(PlannedContainer)
}

@MainActor
private func bindChildren(_ children: [PlannedNode], to parent: TilingContainer) {
    for child in children {
        switch child {
            case .window(let window, let weight):
                window.bind(to: parent, adaptiveWeight: weight ?? WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .container(let c):
                let container = TilingContainer(parent: parent, adaptiveWeight: c.weight ?? WEIGHT_AUTO, c.orientation, c.layout, index: INDEX_BIND_LAST)
                bindChildren(c.children, to: container)
        }
    }
}
