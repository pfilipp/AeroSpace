import AppKit
import Common

struct DumpTreeCommand: Command {
    let args: DumpTreeCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let focus = focus
        let workspaces: [Workspace] = if args.focusedOnly {
            [focus.workspace]
        } else if let wsName = args.workspaceFilter {
            [Workspace.get(byName: wsName)]
        } else {
            Workspace.all
        }

        var result: [[String: Any]] = []
        for workspace in workspaces {
            result.append(try await dumpWorkspace(workspace, focus: focus))
        }

        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            return io.err("Failed to encode JSON")
        }
        return io.out(jsonString)
    }

    @MainActor
    private func dumpWorkspace(_ workspace: Workspace, focus: LiveFocus) async throws -> [String: Any] {
        var result: [String: Any] = [
            "type": "workspace",
            "name": workspace.name,
            "is-visible": workspace.isVisible,
            "is-focused": focus.workspace == workspace,
            "monitor": workspace.workspaceMonitor.name,
        ]

        result["root-container"] = try await dumpTilingContainer(workspace.rootTilingContainer, focus: focus)

        var floatingWindows: [[String: Any]] = []
        for window in workspace.floatingWindows {
            floatingWindows.append(try await dumpWindow(window, focus: focus))
        }
        result["floating-windows"] = floatingWindows

        let fullscreenWindows = workspace.macOsNativeFullscreenWindowsContainer.children
            .filterIsInstance(of: Window.self)
        var fullscreenWindowsResult: [[String: Any]] = []
        for window in fullscreenWindows {
            fullscreenWindowsResult.append(try await dumpWindow(window, focus: focus))
        }
        result["macos-fullscreen-windows"] = fullscreenWindowsResult

        return result
    }

    @MainActor
    private func dumpTilingContainer(_ container: TilingContainer, focus: LiveFocus) async throws -> [String: Any] {
        let layoutStr = switch (container.layout, container.orientation) {
            case (.tiles, .h): "h_tiles"
            case (.tiles, .v): "v_tiles"
            case (.accordion, .h): "h_accordion"
            case (.accordion, .v): "v_accordion"
        }

        var children: [[String: Any]] = []
        for child in container.children {
            switch child.nodeCases {
                case .tilingContainer(let tc):
                    children.append(try await dumpTilingContainer(tc, focus: focus))
                case .window(let w):
                    children.append(try await dumpWindow(w, focus: focus))
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
    private func dumpWindow(_ window: Window, focus: LiveFocus) async throws -> [String: Any] {
        return [
            "type": "window",
            "window-id": window.windowId,
            "app-bundle-id": window.app.rawAppBundleId ?? "unknown",
            "app-name": window.app.name ?? "unknown",
            "title": try await window.title,
            "is-focused": focus.windowOrNil?.windowId == window.windowId,
        ]
    }
}
