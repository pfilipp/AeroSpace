import AppKit
import Common

struct TreeCommand: Command {
    let args: TreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let focus = focus
        let workspaces: [Workspace] = if args.focusedOnly {
            [focus.workspace]
        } else if let wsName = args.workspaceFilter {
            [Workspace.get(byName: wsName)]
        } else {
            Workspace.all
        }

        do {
            if args.json {
                var result: [[String: Any]] = []
                for workspace in workspaces {
                    result.append(try await dumpWorkspaceJson(workspace, focus: focus))
                }

                let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                    return .fail(io.err("Failed to encode JSON"))
                }
                return .succ(io.out(jsonString))
            } else {
                var lines: [String] = []
                for (i, workspace) in workspaces.enumerated() {
                    if i > 0 { lines.append("") }
                    try await renderWorkspaceText(workspace, focus: focus, into: &lines)
                }
                return .succ(io.out(lines.joined(separator: "\n")))
            }
        } catch {
            return .fail(io.err("tree command failed: \(error)"))
        }
    }

    // MARK: - JSON output

    @MainActor
    private func dumpWorkspaceJson(_ workspace: Workspace, focus: LiveFocus) async throws -> [String: Any] {
        var result: [String: Any] = [
            "type": "workspace",
            "name": workspace.name,
            "is-visible": workspace.isVisible,
            "is-focused": focus.workspace == workspace,
            "monitor": workspace.workspaceMonitor.name,
        ]

        if args.floatingWindowsAsTilingWindows {
            result["root-container"] = try await dumpTilingContainerJsonMerged(workspace, focus: focus)
        } else {
            result["root-container"] = try await dumpTilingContainerJson(workspace.rootTilingContainer, focus: focus)

            var floatingWindows: [[String: Any]] = []
            for window in workspace.floatingWindows {
                floatingWindows.append(try await dumpWindowJson(window, focus: focus))
            }
            result["floating-windows"] = floatingWindows
        }

        let fullscreenWindows = workspace.macOsNativeFullscreenWindowsContainer.children
            .filterIsInstance(of: Window.self)
        var fullscreenWindowsResult: [[String: Any]] = []
        for window in fullscreenWindows {
            fullscreenWindowsResult.append(try await dumpWindowJson(window, focus: focus))
        }
        result["macos-fullscreen-windows"] = fullscreenWindowsResult

        return result
    }

    @MainActor
    private func dumpTilingContainerJsonMerged(_ workspace: Workspace, focus: LiveFocus) async throws -> [String: Any] {
        let container = workspace.rootTilingContainer
        let layoutStr = layoutString(container)

        var children: [[String: Any]] = []
        for child in container.children {
            switch child.nodeCases {
                case .tilingContainer(let tc):
                    children.append(try await dumpTilingContainerJson(tc, focus: focus))
                case .window(let w):
                    children.append(try await dumpWindowJson(w, focus: focus))
                default:
                    children.append(["type": "unknown"] as [String: Any])
            }
        }
        for window in workspace.floatingWindows {
            children.append(try await dumpWindowJson(window, focus: focus))
        }

        return [
            "type": "container",
            "layout": layoutStr,
            "orientation": container.orientation == .h ? "horizontal" : "vertical",
            "children": children,
        ]
    }

    @MainActor
    private func dumpTilingContainerJson(_ container: TilingContainer, focus: LiveFocus) async throws -> [String: Any] {
        let layoutStr = layoutString(container)

        var children: [[String: Any]] = []
        for child in container.children {
            switch child.nodeCases {
                case .tilingContainer(let tc):
                    children.append(try await dumpTilingContainerJson(tc, focus: focus))
                case .window(let w):
                    children.append(try await dumpWindowJson(w, focus: focus))
                default:
                    children.append(["type": "unknown"] as [String: Any])
            }
        }

        return [
            "type": "container",
            "layout": layoutStr,
            "orientation": container.orientation == .h ? "horizontal" : "vertical",
            "children": children,
        ]
    }

    @MainActor
    private func dumpWindowJson(_ window: Window, focus: LiveFocus) async throws -> [String: Any] {
        return [
            "type": "window",
            "window-id": window.windowId,
            "app-bundle-id": window.app.rawAppBundleId ?? "unknown",
            "app-name": window.app.name ?? "unknown",
            "title": try await window.getTitle(.nonCancellable),
            "is-focused": focus.windowOrNil?.windowId == window.windowId,
        ]
    }

    // MARK: - Text tree output

    @MainActor
    private func renderWorkspaceText(_ workspace: Workspace, focus: LiveFocus, into lines: inout [String]) async throws {
        let isFocused = focus.workspace == workspace
        var attrs: [String] = []
        if isFocused { attrs.append("focused") }
        if workspace.isVisible { attrs.append("visible") }
        attrs.append("monitor: \"\(workspace.workspaceMonitor.name)\"")
        let attrStr = attrs.joined(separator: ", ")

        lines.append("Workspace \"\(workspace.name)\" (\(attrStr))")

        let container = workspace.rootTilingContainer
        let floatingWindows = workspace.floatingWindows
        let fullscreenWindows = workspace.macOsNativeFullscreenWindowsContainer.children
            .filterIsInstance(of: Window.self)

        if args.floatingWindowsAsTilingWindows {
            var allChildren: [TreeNodeChild] = container.children.map { .tiling($0) }
            for w in floatingWindows {
                allChildren.append(.floating(w))
            }
            let layoutStr = layoutString(container)
            lines.append("\(BOX_LAST)\(BOX_H) [\(layoutStr)]")
            try await renderMergedChildren(allChildren, focus: focus, prefix: "    ", into: &lines)
        } else {
            let hasFloating = !floatingWindows.isEmpty
            let hasFullscreen = !fullscreenWindows.isEmpty
            let isLastSection = !hasFloating && !hasFullscreen

            let connector = isLastSection ? BOX_LAST : BOX_TEE
            let childPrefix = isLastSection ? "    " : BOX_PIPE_PAD
            let layoutStr = layoutString(container)
            lines.append("\(connector)\(BOX_H) [\(layoutStr)]")
            try await renderTilingContainerChildren(container.children, focus: focus, prefix: childPrefix, into: &lines)

            if hasFloating {
                let floatingIsLast = !hasFullscreen
                let floatingConnector = floatingIsLast ? BOX_LAST : BOX_TEE
                let floatingPrefix = floatingIsLast ? "    " : BOX_PIPE_PAD
                lines.append("\(floatingConnector)\(BOX_H) Floating:")
                for (j, window) in floatingWindows.enumerated() {
                    let wConn = j == floatingWindows.count - 1 ? BOX_LAST : BOX_TEE
                    let desc = try await windowDescription(window, focus: focus)
                    lines.append("\(floatingPrefix)\(wConn)\(BOX_H) \(desc)")
                }
            }

            if hasFullscreen {
                lines.append("\(BOX_LAST)\(BOX_H) Fullscreen:")
                for (j, window) in fullscreenWindows.enumerated() {
                    let wConn = j == fullscreenWindows.count - 1 ? BOX_LAST : BOX_TEE
                    let desc = try await windowDescription(window, focus: focus)
                    lines.append("    \(wConn)\(BOX_H) \(desc)")
                }
            }
        }
    }

    private enum TreeNodeChild {
        case tiling(TreeNode)
        case floating(Window)
    }

    @MainActor
    private func renderMergedChildren(_ children: [TreeNodeChild], focus: LiveFocus, prefix: String, into lines: inout [String]) async throws {
        for (i, child) in children.enumerated() {
            let isLast = i == children.count - 1
            let connector = isLast ? BOX_LAST : BOX_TEE
            let childPrefix = prefix + (isLast ? "    " : BOX_PIPE_PAD)

            switch child {
                case .tiling(let node):
                    switch node.nodeCases {
                        case .tilingContainer(let tc):
                            let layoutStr = layoutString(tc)
                            lines.append("\(prefix)\(connector)\(BOX_H) [\(layoutStr)]")
                            try await renderTilingContainerChildren(tc.children, focus: focus, prefix: childPrefix, into: &lines)
                        case .window(let w):
                            let desc = try await windowDescription(w, focus: focus)
                            lines.append("\(prefix)\(connector)\(BOX_H) \(desc)")
                        default:
                            lines.append("\(prefix)\(connector)\(BOX_H) [unknown]")
                    }
                case .floating(let w):
                    let desc = try await windowDescription(w, focus: focus)
                    lines.append("\(prefix)\(connector)\(BOX_H) \(desc) (floating)")
            }
        }
    }

    @MainActor
    private func renderTilingContainerChildren(_ children: [TreeNode], focus: LiveFocus, prefix: String, into lines: inout [String]) async throws {
        for (i, child) in children.enumerated() {
            let isLast = i == children.count - 1
            let connector = isLast ? BOX_LAST : BOX_TEE
            let childPrefix = prefix + (isLast ? "    " : BOX_PIPE_PAD)

            switch child.nodeCases {
                case .tilingContainer(let tc):
                    let layoutStr = layoutString(tc)
                    lines.append("\(prefix)\(connector)\(BOX_H) [\(layoutStr)]")
                    try await renderTilingContainerChildren(tc.children, focus: focus, prefix: childPrefix, into: &lines)
                case .window(let w):
                    let desc = try await windowDescription(w, focus: focus)
                    lines.append("\(prefix)\(connector)\(BOX_H) \(desc)")
                default:
                    lines.append("\(prefix)\(connector)\(BOX_H) [unknown]")
            }
        }
    }

    @MainActor
    private func windowDescription(_ window: Window, focus: LiveFocus) async throws -> String {
        let appName = window.app.name ?? "unknown"
        let title = try await window.getTitle(.nonCancellable)
        let isFocused = focus.windowOrNil?.windowId == window.windowId
        let focusMarker = isFocused ? " *" : ""
        return "[\(window.windowId)] \(appName) \u{2014} \"\(title)\"\(focusMarker)"
    }

    // MARK: - Helpers

    private func layoutString(_ container: TilingContainer) -> String {
        switch (container.layout, container.orientation) {
            case (.tiles, .h): "h_tiles"
            case (.tiles, .v): "v_tiles"
            case (.accordion, .h): "h_accordion"
            case (.accordion, .v): "v_accordion"
        }
    }
}

// Box-drawing constants
private let BOX_TEE = "\u{251C}"       // ├
private let BOX_LAST = "\u{2514}"      // └
private let BOX_H = "\u{2500}\u{2500}" // ──
private let BOX_PIPE_PAD = "\u{2502}   " // │   (pipe + 3 spaces)
