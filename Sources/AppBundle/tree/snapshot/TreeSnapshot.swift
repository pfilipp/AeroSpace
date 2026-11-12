import AppKit
import Common

struct TreeSnapshotWindow: Equatable {
    let windowId: UInt32
    let weight: CGFloat?
}

struct TreeSnapshotContainer: Equatable {
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat?
    let children: [TreeSnapshotNode]
}

indirect enum TreeSnapshotNode: Equatable {
    case container(TreeSnapshotContainer)
    case window(TreeSnapshotWindow)
}

struct TreeSnapshotWorkspace: Equatable {
    let name: String
    let root: TreeSnapshotContainer
    let floatingWindows: [TreeSnapshotWindow]
}

/// Parses snapshot JSON (the output of `tree --json`). Fails on: invalid JSON, top level not an array,
/// missing `name`/`root-container`, unknown `layout`, a `window-id` appearing more than once in the whole document.
/// Every other key is ignored.
func parseTreeSnapshot(_ json: String) -> Result<[TreeSnapshotWorkspace], String> {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data)
    else { return .failure("Invalid JSON") }
    guard let array = parsed as? [Any] else { return .failure("Top level must be an array of workspaces") }
    var seenWindowIds: Set<UInt32> = []
    var result: [TreeSnapshotWorkspace] = []
    for (i, element) in array.enumerated() {
        guard let dict = element as? [String: Any] else { return .failure("Workspace #\(i) is not an object") }
        guard let name = dict["name"] as? String else { return .failure("Workspace #\(i) has no 'name'") }
        guard let rootDict = dict["root-container"] as? [String: Any] else {
            return .failure("Workspace '\(name)' has no 'root-container'")
        }
        let root: TreeSnapshotContainer
        switch parseContainer(rootDict, &seenWindowIds) {
            case .success(let c): root = c
            case .failure(let e): return .failure("Workspace '\(name)': \(e)")
        }
        var floating: [TreeSnapshotWindow] = []
        for w in (dict["floating-windows"] as? [Any]) ?? [] {
            guard let wDict = w as? [String: Any] else { return .failure("Workspace '\(name)': floating window is not an object") }
            switch parseWindow(wDict, &seenWindowIds) {
                case .success(let window): floating.append(window)
                case .failure(let e): return .failure("Workspace '\(name)': \(e)")
            }
        }
        result.append(TreeSnapshotWorkspace(name: name, root: root, floatingWindows: floating))
    }
    return .success(result)
}

private func parseContainer(_ dict: [String: Any], _ seen: inout Set<UInt32>) -> Result<TreeSnapshotContainer, String> {
    guard let layoutStr = dict["layout"] as? String else { return .failure("container has no 'layout'") }
    let layout: Layout
    let orientation: Orientation
    switch layoutStr {
        case "h_tiles": (layout, orientation) = (.tiles, .h)
        case "v_tiles": (layout, orientation) = (.tiles, .v)
        case "h_accordion": (layout, orientation) = (.accordion, .h)
        case "v_accordion": (layout, orientation) = (.accordion, .v)
        default: return .failure("unknown layout '\(layoutStr)'")
    }
    var children: [TreeSnapshotNode] = []
    for child in (dict["children"] as? [Any]) ?? [] {
        guard let childDict = child as? [String: Any] else { return .failure("child is not an object") }
        if childDict["window-id"] != nil {
            switch parseWindow(childDict, &seen) {
                case .success(let w): children.append(.window(w))
                case .failure(let e): return .failure(e)
            }
        } else {
            switch parseContainer(childDict, &seen) {
                case .success(let c): children.append(.container(c))
                case .failure(let e): return .failure(e)
            }
        }
    }
    return .success(TreeSnapshotContainer(layout: layout, orientation: orientation, weight: weightOf(dict), children: children))
}

private func parseWindow(_ dict: [String: Any], _ seen: inout Set<UInt32>) -> Result<TreeSnapshotWindow, String> {
    guard let number = dict["window-id"] as? NSNumber, let id = UInt32(exactly: number.int64Value) else {
        return .failure("window has no valid 'window-id'")
    }
    if !seen.insert(id).inserted { return .failure("duplicate window-id \(id)") }
    return .success(TreeSnapshotWindow(windowId: id, weight: weightOf(dict)))
}

private func weightOf(_ dict: [String: Any]) -> CGFloat? {
    (dict["weight"] as? NSNumber).map { CGFloat($0.doubleValue) }
}
