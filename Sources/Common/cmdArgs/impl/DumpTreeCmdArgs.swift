public struct DumpTreeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .dumpTree,
        allowInConfig: false,
        help: dump_tree_help_generated,
        flags: [
            "--workspace": singleValueSubArgParser(\.workspaceFilter, "<workspace>") { $0 },
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
