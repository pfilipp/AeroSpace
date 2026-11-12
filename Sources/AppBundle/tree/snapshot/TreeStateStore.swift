import AppKit
import Common

struct PersistedTreeState {
    let bootTime: Int
    let bootSession: String
    let writtenAt: Int
    let visibleWorkspaces: [(topLeft: CGPoint, workspace: String)]
    let workspaces: [TreeSnapshotWorkspace]
}

private let keptPreviousStates = 5

// MARK: - Paths and boot time

@MainActor var treeStateDirOverride: URL? = nil
@MainActor var bootTimeOverride: Int? = nil
@MainActor var bootSessionOverride: String? = nil

/// `$XDG_STATE_HOME/aerospace` when set and non-empty, else `<home>/.local/state/aerospace`.
func resolveTreeStateDir(env: [String: String], home: URL) -> URL {
    if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
        return URL(fileURLWithPath: xdg).appendingPathComponent("aerospace")
    }
    return home.appendingPathComponent(".local/state/aerospace")
}

@MainActor var treeStateDir: URL {
    treeStateDirOverride ?? resolveTreeStateDir(env: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
}

@MainActor private var currentStateFile: URL { treeStateDir.appendingPathComponent("current.json") }
@MainActor private var previousStatesDir: URL { treeStateDir.appendingPathComponent("previous") }

@MainActor func currentBootTime() -> Int {
    if let bootTimeOverride { return bootTimeOverride }
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return Int(tv.tv_sec)
}

/// Per-boot UUID (`kern.bootsessionuuid`); unlike `kern.boottime` it is unaffected by wall-clock steps.
@MainActor func currentBootSession() -> String {
    if let bootSessionOverride { return bootSessionOverride }
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

// MARK: - Encode

/// Serialises the live tree into the state-file JSON string (envelope + workspaces).
@MainActor func encodeCurrentTreeState(now: Int) async -> String {
    let visible: [[String: Any]] = monitorInfos.map {
        let corner = $0.rect.topLeftCorner
        return ["monitor-top-left": [Double(corner.x), Double(corner.y)], "workspace": $0.activeWorkspace.name]
    }
    var envelope: [String: Any] = [
        "version": 1,
        "boot-time": currentBootTime(),
        "boot-session": currentBootSession(),
        "written-at": now,
        "visible-workspaces": visible,
        "workspaces": await dumpWorkspacesForJson(Workspace.all),
    ]
    // `JSONSerialization.data` raises an uncatchable Objective-C exception on NaN/infinity
    if !JSONSerialization.isValidJSONObject(envelope) {
        envelope = treeStateJsonDroppingNonFiniteWeights(envelope) as? [String: Any] ?? [:]
        if !JSONSerialization.isValidJSONObject(envelope) { return "" }
    }
    let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Returns `value` with every `weight` entry that is not a finite number removed, recursively
func treeStateJsonDroppingNonFiniteWeights(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, child) in dict {
            if key == "weight", let number = jsonNumberAsDouble(child), !number.isFinite { continue }
            result[key] = treeStateJsonDroppingNonFiniteWeights(child)
        }
        return result
    }
    if let array = value as? [Any] { return array.map(treeStateJsonDroppingNonFiniteWeights) }
    return value
}

private func jsonNumberAsDouble(_ value: Any) -> Double? {
    if let v = value as? CGFloat { return Double(v) }
    if let v = value as? Double { return v }
    if let v = value as? Float { return Double(v) }
    if let v = value as? NSNumber { return v.doubleValue }
    return nil
}

// MARK: - Write

/// Writes `current.json` atomically, creating the directory.
@MainActor func writeCurrentTreeState(_ json: String) throws {
    try FileManager.default.createDirectory(at: treeStateDir, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: currentStateFile, options: .atomic)
}

// MARK: - Rotate and prune

/// Moves `current.json` to `previous/<written-at>.json`, deletes all but the 5 newest in `previous/`,
/// and returns the moved state. Returns nil when there is no readable, parseable `current.json`
/// (a corrupt file is still moved aside, named by its modification time). Never throws.
@MainActor func rotateTreeStateAtLaunch() -> PersistedTreeState? {
    let fm = FileManager.default
    let current = currentStateFile
    guard fm.fileExists(atPath: current.path) else { return nil }
    let state = (try? Data(contentsOf: current)).flatMap { decodeTreeState($0) }
    let name: Int = state?.writtenAt
        ?? ((try? fm.attributesOfItem(atPath: current.path)[.modificationDate]) as? Date).map { Int($0.timeIntervalSince1970) }
        ?? Int(Date().timeIntervalSince1970)
    do {
        try fm.createDirectory(at: previousStatesDir, withIntermediateDirectories: true)
        let target = previousStatesDir.appendingPathComponent("\(name).json")
        try? fm.removeItem(at: target) // same-second collision: overwrite
        try fm.moveItem(at: current, to: target)
    } catch {
        try? fm.removeItem(at: current) // never leave a stale file that would be re-read as current
    }
    prunePreviousStates()
    return state
}

/// Keeps the 5 newest files, plus the newest readable file from another boot when it is older than those,
/// so restarts after a reboot never push the pre-reboot arrangement out
@MainActor private func prunePreviousStates() {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: previousStatesDir.path) else { return }
    let newestFirst = names.compactMap { n -> (Int, String)? in
        n.hasSuffix(".json") ? Int(n.dropLast(5)).map { ($0, n) } : nil
    }.sorted(by: { $0.0 > $1.0 }).map(\.1)
    if newestFirst.count <= keptPreviousStates { return }
    let bootSession = currentBootSession()
    let protected = newestFirst.first { name in
        let state = (try? Data(contentsOf: previousStatesDir.appendingPathComponent(name))).flatMap { decodeTreeState($0) }
        return state.map { $0.bootSession != bootSession } ?? false
    }
    for n in newestFirst.dropFirst(keptPreviousStates) where n != protected {
        try? fm.removeItem(at: previousStatesDir.appendingPathComponent(n))
    }
}

// MARK: - Decode

private func decodeTreeState(_ data: Data) -> PersistedTreeState? {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          obj["version"] as? Int == 1,
          let bootTime = obj["boot-time"] as? Int,
          let bootSession = obj["boot-session"] as? String, !bootSession.isEmpty,
          let writtenAt = obj["written-at"] as? Int,
          let workspacesArray = obj["workspaces"] as? [Any],
          let workspacesData = try? JSONSerialization.data(withJSONObject: workspacesArray),
          let workspacesJson = String(data: workspacesData, encoding: .utf8),
          case .success(let workspaces) = parseTreeSnapshot(workspacesJson)
    else { return nil }
    let visible = ((obj["visible-workspaces"] as? [[String: Any]]) ?? []).compactMap { entry -> (topLeft: CGPoint, workspace: String)? in
        guard let corner = entry["monitor-top-left"] as? [Double], corner.count == 2,
              let name = entry["workspace"] as? String
        else { return nil }
        return (CGPoint(x: corner[0], y: corner[1]), name)
    }
    return PersistedTreeState(bootTime: bootTime, bootSession: bootSession, writtenAt: writtenAt, visibleWorkspaces: visible, workspaces: workspaces)
}

// MARK: - Signature

/// Stable description of the tree that excludes titles and focus; equal strings mean nothing worth writing changed.
@MainActor func treeStructureSignature() -> String {
    var out = ""
    for monitor in monitorInfos {
        let corner = monitor.rect.topLeftCorner
        out += "mon(\(corner.x),\(corner.y))=\(monitor.activeWorkspace.name);"
    }
    for ws in Workspace.all {
        out += "ws(\(ws.name)){"
        signature(ws.rootTilingContainer, parentOrientation: nil, &out)
        out += "}float["
        for w in ws.floatingWindows { out += "\(w.windowId)," }
        out += "]"
    }
    return out
}

@MainActor private func signature(_ node: TreeNode, parentOrientation: Orientation?, _ out: inout String) {
    // Rounded to whole points: layout arithmetic jitters weights by fractions on every layout
    let weight = parentOrientation.map { "@" + String(format: "%.0f", node.getWeight($0)) } ?? ""
    if let window = node as? Window {
        out += "w\(window.windowId)\(weight);"
    } else if let container = node as? TilingContainer {
        out += "c(\(container.layout),\(container.orientation))\(weight){"
        for child in container.children { signature(child, parentOrientation: container.orientation, &out) }
        out += "}"
    }
}
