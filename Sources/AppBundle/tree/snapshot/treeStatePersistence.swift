import AppKit
import Common

/// Minimum time between two writes of `current.json`. Injectable for tests
@MainActor var treeStateWriteThrottleInterval: TimeInterval = 2
/// Number of deferred writes scheduled since the last reset. Test-visible
@MainActor private(set) var treeStateDeferredWritesScheduled = 0

/// Off until the launch-time restore has run, so the pile-up right after a restart never replaces the saved tree
@MainActor private var isTreeStateWritingEnabled = false
@MainActor private var lastWrittenTreeSignature: String? = nil
@MainActor private var lastTreeStateWriteAttempt: ContinuousClock.Instant? = nil
@MainActor private var deferredTreeStateWrite: Task<(), Never>? = nil
@MainActor private var isTreeStateWriteFailureReported = false

@MainActor func resetTreeStatePersistenceForTests() {
    deferredTreeStateWrite?.cancel()
    deferredTreeStateWrite = nil
    isTreeStateWritingEnabled = false
    lastWrittenTreeSignature = nil
    lastTreeStateWriteAttempt = nil
    isTreeStateWriteFailureReported = false
    treeStateDeferredWritesScheduled = 0
    treeStateWriteThrottleInterval = 2
}

/// Launch step. No-op unless config.persistTreeState. Rotates; if the rotated state is from this boot,
/// applies it and sets each recorded monitor's visible workspace. Returns true when a state was applied.
/// Enables writing afterwards in every case.
///
/// The caller must make sure a model refresh and layout follow
@MainActor func restoreTreeStateAtLaunch() -> Bool {
    defer { isTreeStateWritingEnabled = true }
    guard config.persistTreeState, let state = rotateTreeStateAtLaunch() else { return false }
    let bootSession = currentBootSession()
    guard !bootSession.isEmpty, state.bootSession == bootSession else { return false } // Left in previous/ for external tools
    _ = applyTreeSnapshot(state.workspaces)
    let topLeftCornerToMonitor = monitorInfos.grouped { $0.rect.topLeftCorner }
    for (topLeft, workspaceName) in state.visibleWorkspaces {
        _ = topLeftCornerToMonitor[topLeft]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: workspaceName))
    }
    return true
}

/// Refresh hook. No-op unless config.persistTreeState, writing is enabled, and not `isStartup`.
/// Writes when `treeStructureSignature()` differs from the last written one, at most once every 2 seconds;
/// a change inside that window is written by one deferred task when the window ends.
@MainActor func persistTreeStateIfChanged() async {
    guard !isStartup, isTreeStateWriteDue() else { return }
    if let last = lastTreeStateWriteAttempt {
        let remaining = .seconds(treeStateWriteThrottleInterval) - (ContinuousClock.now - last)
        if remaining > .zero {
            scheduleDeferredTreeStateWrite(after: remaining)
            return
        }
    }
    await writeTreeStateNow()
}

/// Cheap: no filesystem or accessibility access
@MainActor private func isTreeStateWriteDue() -> Bool {
    config.persistTreeState && isTreeStateWritingEnabled && TrayMenuModel.shared.isEnabled &&
        treeStructureSignature() != lastWrittenTreeSignature
}

@MainActor private func scheduleDeferredTreeStateWrite(after delay: Duration) {
    if deferredTreeStateWrite != nil { return } // At most one pending
    treeStateDeferredWritesScheduled += 1
    deferredTreeStateWrite = Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: delay)
        if Task.isCancelled { return }
        deferredTreeStateWrite = nil
        if isTreeStateWriteDue() { await writeTreeStateNow() }
    }
}

/// Never throws: a failure is reported once per failure streak and retried on the next change
@MainActor private func writeTreeStateNow() async {
    let signature = treeStructureSignature()
    lastTreeStateWriteAttempt = .now
    let json = await encodeCurrentTreeState(now: Int(Date().timeIntervalSince1970))
    do {
        try writeCurrentTreeState(json)
        lastWrittenTreeSignature = signature
        isTreeStateWriteFailureReported = false
    } catch {
        if !isTreeStateWriteFailureReported {
            isTreeStateWriteFailureReported = true
            print("persist-tree-state: can't write \(treeStateDir.path): \(error)")
        }
    }
}
