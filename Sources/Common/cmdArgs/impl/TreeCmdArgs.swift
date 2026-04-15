public struct TreeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .tree,
        help: tree_help_generated,
        flags: [
            "--workspace": singleValueSubArgParser(\.workspaceFilter, "<workspace>", Result.success),
            "--focused": trueBoolFlag(\.focusedOnly),
            "--json": trueBoolFlag(\.json),
            "--floating-windows-as-tiling-windows": trueBoolFlag(\.floatingWindowsAsTilingWindows),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--workspace", "--focused"],
        ],
    )

    public var workspaceFilter: String? = nil
    public var focusedOnly: Bool = false
    public var json: Bool = false
    public var floatingWindowsAsTilingWindows: Bool = false
}
