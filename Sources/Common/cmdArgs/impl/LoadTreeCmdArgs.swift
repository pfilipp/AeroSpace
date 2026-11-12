public struct LoadTreeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .loadTree,
        help: load_tree_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.path, consumeStrCliArg, placeholder: "<absolute-path>")],
    )

    public var path: Lateinit<String> = .uninitialized
}
