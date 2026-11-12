import Common

/// A user-defined entry in the menu-bar (tray) menu, declared as `[[menu-bar-item]]` in the config
struct MenuBarItem: Equatable {
    let label: String
    let run: Shell<any Command>

    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.label == rhs.label && lhs.run.strictEquals(rhs.run)
    }
}

private struct RawMenuBarItem: ConvenienceMutable {
    var label: String? = nil
    var run: Shell<any Command>? = nil
}

private let menuBarItemParser: [String: any ParserProtocol<RawMenuBarItem>] = [
    "label": Parser(\.label, parseMenuBarItemLabel),
    "run": Parser(\.run, parseShellOfCommandsForConfig),
]

private func parseMenuBarItemLabel(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String?> {
    parseString(raw, backtrace)
        .filter(.init(backtrace, "'label' must not be empty")) { !$0.isEmpty }
        .map(Optional.init)
}

func parseMenuBarItemArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [MenuBarItem] {
    if let array = raw.asArrayOrNil {
        return array.enumerated().map { (index, raw) in parseMenuBarItem(raw, backtrace + .index(index), &c) }.filterNotNil()
    } else {
        c.errors += [expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace)]
        return []
    }
}

private func parseMenuBarItem(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> MenuBarItem? {
    var myContext = ConfigParserContext(configVersion: c.configVersion, errors: [], warnings: [])
    let item = parseTable(raw, RawMenuBarItem(), menuBarItemParser, backtrace, &myContext)

    if let dict = raw.asDictOrNil {
        for key in ["label", "run"] where dict[key] == nil {
            myContext.errors.append(.init(backtrace, "'\(key)' is mandatory key"))
        }
    }

    c.errors += myContext.errors
    c.warnings += myContext.warnings
    guard myContext.errors.isEmpty, let label = item.label, let run = item.run else { return nil }
    return MenuBarItem(label: label, run: run)
}

/// Action of a `[[menu-bar-item]]` button: run its commands in order, in a light session
@MainActor
func runMenuBarItem(_ item: MenuBarItem, _ token: RunSessionGuard) async throws {
    try await runLightSession(.menuBarButton, token) {
        await runMenuBarItemCommands(item)
    }
}

/// Split out of `runMenuBarItem` for unit tests: a light session lays windows out, which only works with real `MacWindow`s
@MainActor
func runMenuBarItemCommands(_ item: MenuBarItem) async {
    _ = await item.run.run(.defaultEnv, .emptyStdin)
}
