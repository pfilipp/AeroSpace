import AppKit
import Common

/// Minimum time between two writes of `current.json`. Injectable for tests
@MainActor var treeStateWriteThrottleInterval: TimeInterval = 2
/// Number of deferred writes scheduled since the last reset. Test-visible
@MainActor private(set) var treeStateDeferredWritesScheduled = 0
@MainActor var isTreeStateDeferredWritePending: Bool { deferredTreeStateWrite != nil }

/// Off until the launch-time restore has run, so the pile-up right after a restart never replaces the saved tree
@MainActor private var isTreeStateWritingEnabled = false
/// `current.json` has been set aside into `previous/` in this process (at launch, or before the first write)
@MainActor private var isTreeStateRotationDone = false
/// Set for good once the session starts powering off: apps quitting would otherwise be saved as a torn-down tree
@MainActor private var isTreeStatePoweringOff = false
@MainActor private var lastWrittenTreeSignature: String? = nil
@MainActor private var lastTreeStateWriteAttempt: ContinuousClock.Instant? = nil
@MainActor private var deferredTreeStateWrite: Task<(), Never>? = nil
@MainActor private var isTreeStateWriteFailureReported = false
@MainActor private var powerOffObserver: (any NSObjectProtocol)? = nil

@MainActor func resetTreeStatePersistenceForTests() {
    deferredTreeStateWrite?.cancel()
    deferredTreeStateWrite = nil
    if let powerOffObserver { NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver) }
    powerOffObserver = nil
    isTreeStateWritingEnabled = false
    isTreeStateRotationDone = false
    isTreeStatePoweringOff = false
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
/// Focus follows the window that was focused before the restore to its restored workspace (that workspace wins on
/// its monitor); every other monitor shows its recorded workspace. The caller must make sure a model refresh and
/// layout follow
@MainActor func restoreTreeStateAtLaunch() -> Bool {
    defer { isTreeStateWritingEnabled = true }
    guard config.persistTreeState else { return false }
    registerTreeStatePowerOffObserverOnce()
    isTreeStateRotationDone = true
    guard let state = rotateTreeStateAtLaunch() else { return false }
    let bootSession = currentBootSession()
    guard !bootSession.isEmpty, state.bootSession == bootSession else { return false } // Left in previous/ for external tools

    let focusedWindow = focus.windowOrNil // Captured before: the apply may move it out of the focused workspace
    _ = applyTreeSnapshot(state.workspaces)
    let topLeftCornerToMonitor = monitorInfos.grouped { $0.rect.topLeftCorner }
    for (topLeft, workspaceName) in state.visibleWorkspaces {
        _ = topLeftCornerToMonitor[topLeft]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: workspaceName))
    }
    if let focusedWindow, Window.get(byId: focusedWindow.windowId) != nil, focusedWindow.focusWindow() {
        // Focus and its monitor's visible workspace follow the window
    } else {
        _ = mainMonitorInfo.activeWorkspace.focusWorkspace()
    }
    // `setFocus` returns early when the focus didn't change, so it doesn't re-show a workspace the loop above hid
    let focusedWorkspace = focus.workspace
    if !focusedWorkspace.isVisible { _ = focusedWorkspace.workspaceMonitor.setActiveWorkspace(focusedWorkspace) }
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

/// Handler for `NSWorkspace.willPowerOffNotification` (logout, restart, shut down). Disables writing for the rest of
/// the process so the saved tree is the one from before apps started quitting
@MainActor func treeStatePersistenceWillPowerOff() {
    isTreeStatePoweringOff = true
    deferredTreeStateWrite?.cancel()
    deferredTreeStateWrite = nil
}

@MainActor private func registerTreeStatePowerOffObserverOnce() {
    if powerOffObserver != nil { return }
    powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willPowerOffNotification,
        object: nil,
        queue: .main,
    ) { _ in
        MainActor.assumeIsolated { treeStatePersistenceWillPowerOff() }
    }
}

/// Cheap: no filesystem or accessibility access
@MainActor private func isTreeStateWriteDue() -> Bool {
    config.persistTreeState && isTreeStateWritingEnabled && !isTreeStatePoweringOff && TrayMenuModel.shared.isEnabled &&
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
    registerTreeStatePowerOffObserverOnce()
    let signature = treeStructureSignature()
    lastTreeStateWriteAttempt = .now
    let json = await encodeCurrentTreeState(now: Int(Date().timeIntervalSince1970))
    // The encode suspends per window (title reads); re-check everything that may have changed meanwhile
    guard config.persistTreeState, !isTreeStatePoweringOff, !json.isEmpty else { return }
    guard treeStructureSignature() == signature else {
        // Torn dump: the tree changed during the encode. Try again once the throttle window ends
        scheduleDeferredTreeStateWrite(after: .seconds(treeStateWriteThrottleInterval))
        return
    }
    if !isTreeStateRotationDone {
        // The launch didn't set the saved tree aside (the option was off then). Do it before replacing it
        isTreeStateRotationDone = true
        _ = rotateTreeStateAtLaunch()
    }
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
