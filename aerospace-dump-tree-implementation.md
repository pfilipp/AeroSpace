# AeroSpace Fork: `dump-tree` Command Implementation

## Overview

Add `aerospace dump-tree` command that outputs the full tree hierarchy in JSON format (similar to i3's `i3-msg -t get_tree`).

**Repository:** https://github.com/nikitabobko/AeroSpace

---

## Files to Create

### 1. `Sources/Common/cmdArgs/impl/DumpTreeCmdArgs.swift`

```swift
public struct DumpTreeCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .dumpTree,
        allowInConfig: false,
        help: dump_tree_help_generated,
        flags: [
            "--workspace": ArgParser(\.workspaceFilter, parseWorkspaceFilter),
            "--focused": trueBoolFlag(\.focusedOnly),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--workspace", "--focused"],
        ],
    )

    public var workspaceFilter: String? = nil
    public var focusedOnly: Bool = false
}

public func parseDumpTreeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<DumpTreeCmdArgs> {
    parseSpecificCmdArgs(DumpTreeCmdArgs(commonState: .init(args)), args)
}

func parseWorkspaceFilter(input: SubArgParserInput) -> ParsedCliArgs<String?> {
    let args = input.nonFlagArgs()
    if args.isEmpty { return .fail("--workspace requires a workspace name") }
    return .succ(args.first, advanceBy: 1)
}
```

### 2. `Sources/AppBundle/command/impl/DumpTreeCommand.swift`

```swift
import AppKit
import Common

struct DumpTreeCommand: Command {
    let args: DumpTreeCmdArgs
    var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let workspaces: [Workspace]

        if args.focusedOnly {
            workspaces = [focus.workspace]
        } else if let wsName = args.workspaceFilter {
            workspaces = [Workspace.get(byName: wsName)]
        } else {
            workspaces = Workspace.all
        }

        var result: [[String: Any]] = []
        for workspace in workspaces {
            result.append(try await dumpWorkspace(workspace))
        }

        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        return io.out(jsonString)
    }

    @MainActor
    private func dumpWorkspace(_ workspace: Workspace) async throws -> [String: Any] {
        var result: [String: Any] = [
            "type": "workspace",
            "name": workspace.name,
            "is-visible": workspace.isVisible,
            "is-focused": focus.workspace == workspace,
            "monitor": workspace.workspaceMonitor.name,
        ]

        // Root tiling container
        let rootContainer = workspace.rootTilingContainer
        result["root-container"] = dumpTilingContainer(rootContainer)

        // Floating windows
        result["floating-windows"] = try await workspace.floatingWindows.asyncMap {
            try await dumpWindow($0)
        }

        // macOS native fullscreen windows
        let fullscreenWindows = workspace.macOsNativeFullscreenWindowsContainer.children
            .filterIsInstance(of: Window.self)
        result["macos-fullscreen-windows"] = try await fullscreenWindows.asyncMap {
            try await dumpWindow($0)
        }

        return result
    }

    @MainActor
    private func dumpTilingContainer(_ container: TilingContainer) -> [String: Any] {
        let layoutStr = switch (container.layout, container.orientation) {
            case (.tiles, .h): "h_tiles"
            case (.tiles, .v): "v_tiles"
            case (.accordion, .h): "h_accordion"
            case (.accordion, .v): "v_accordion"
        }

        return [
            "type": "container",
            "layout": layoutStr,
            "orientation": container.orientation == .h ? "horizontal" : "vertical",
            "children": container.children.map { child in
                switch child.nodeCases {
                case .tilingContainer(let tc):
                    return dumpTilingContainer(tc)
                case .window(let w):
                    // Note: We need async for window title, simplified here
                    return [
                        "type": "window",
                        "window-id": w.windowId,
                        "app-bundle-id": w.app.rawAppBundleId ?? "unknown",
                        "app-name": w.app.name ?? "unknown",
                    ] as [String: Any]
                default:
                    return ["type": "unknown"] as [String: Any]
                }
            }
        ]
    }

    @MainActor
    private func dumpWindow(_ window: Window) async throws -> [String: Any] {
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
```

---

## Files to Modify

### 3. `Sources/Common/cmdArgs/cmdArgsManifest.swift`

**Add to `CmdKind` enum** (keep alphabetical order, after `debugWindows`):

```swift
case dumpTree = "dump-tree"
```

**Add to `initSubcommands()` function** (after `debugWindows` case):

```swift
case .dumpTree:
    result[kind.rawValue] = SubCommandParser(parseDumpTreeCmdArgs)
```

### 4. `Sources/AppBundle/command/cmdManifest.swift`

**Add case to the switch** (after `debugWindows` case):

```swift
case .dumpTree:
    command = DumpTreeCommand(args: self as! DumpTreeCmdArgs)
```

### 5. Generate Help File

You'll need to create `Sources/Common/cmdArgs/impl/dump_tree_help_generated.swift` or use the existing help generation system. Simplest approach:

```swift
let dump_tree_help_generated = """
USAGE: aerospace dump-tree [-h|--help] [--workspace <name>] [--focused]

OPTIONS:
  -h, --help              Print help
  --workspace <name>      Only dump tree for specified workspace
  --focused               Only dump tree for the focused workspace
"""
```

---

## Documentation (Optional)

### `docs/aerospace-dump-tree.adoc`

```asciidoc
= aerospace-dump-tree(1)

== Name
aerospace-dump-tree - Dump the window tree structure as JSON

== Synopsis
[verse]
aerospace dump-tree [-h|--help] [--workspace <workspace>] [--focused]

== Description
Dumps the complete tree structure of all workspaces (or specified workspace) as JSON.
This is useful for debugging, scripting, and understanding the current layout state.

== Options
-h, --help:: Print help
--workspace <workspace>:: Only dump tree for specified workspace
--focused:: Only dump tree for the focused workspace

== Output Format
The output is a JSON array of workspace objects, each containing:
- Workspace metadata (name, visibility, focus state)
- Root tiling container with nested children
- Floating windows
- macOS native fullscreen windows

== Examples
----
# Dump all workspaces
aerospace dump-tree

# Dump only focused workspace
aerospace dump-tree --focused

# Dump specific workspace
aerospace dump-tree --workspace 1
----
```

---

## Example Output

```json
[
  {
    "type": "workspace",
    "name": "1",
    "is-visible": true,
    "is-focused": true,
    "monitor": "Built-in Retina Display",
    "root-container": {
      "type": "container",
      "layout": "h_tiles",
      "orientation": "horizontal",
      "children": [
        {
          "type": "window",
          "window-id": 1234,
          "app-bundle-id": "com.apple.Safari",
          "app-name": "Safari"
        },
        {
          "type": "container",
          "layout": "v_tiles",
          "orientation": "vertical",
          "children": [
            {
              "type": "window",
              "window-id": 5678,
              "app-bundle-id": "org.alacritty",
              "app-name": "Alacritty"
            },
            {
              "type": "window",
              "window-id": 9012,
              "app-bundle-id": "com.microsoft.VSCode",
              "app-name": "Code"
            }
          ]
        }
      ]
    },
    "floating-windows": [],
    "macos-fullscreen-windows": []
  }
]
```

---

## Key Codebase Patterns

| Component | Access Pattern |
|-----------|---------------|
| All workspaces | `Workspace.all` |
| Root container | `workspace.rootTilingContainer` |
| Floating windows | `workspace.floatingWindows` |
| Children traversal | `node.children` + `nodeCases` for type switching |
| Layout info | `container.layout` + `container.orientation` |
| Window title | `window.title` (async) |
| Focus state | `focus.workspace`, `focus.windowOrNil` |

---

## Build & Test

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/AeroSpace.git
cd AeroSpace

# Build
swift build

# Run from build
.build/debug/aerospace dump-tree --focused
```

---

## Notes

1. The `asyncMap` helper may need to be added if not present - it's for mapping async operations over arrays
2. The help generation system uses `.adoc` files that get converted - check how other commands handle this
3. Consider adding `--monitor` filter option for consistency with other list commands
4. The JSON serialization could be improved to use `Codable` for type safety
