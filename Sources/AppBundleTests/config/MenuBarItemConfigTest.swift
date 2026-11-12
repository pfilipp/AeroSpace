@testable import AppBundle
import Common
import XCTest

@MainActor
final class MenuBarItemConfigTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMenuBarItemsDefaultEmpty() {
        let result = parseConfig("")
        assertEquals(result.errors, [])
        assertTrue(result.config.menuBarItems.isEmpty)
        assertTrue(defaultConfig.menuBarItems.isEmpty)
    }

    func testParsesMenuBarItems() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            label = 'Save layout'
            run = 'exec-and-forget echo save'

            [[menu-bar-item]]
            label = 'Restore layout'
            run = ['flatten-workspace-tree', 'layout v_tiles']
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.menuBarItems.map(\.label), ["Save layout", "Restore layout"])
        assertEquals(result.config.menuBarItems.map { $0.run.flatten().count }, [1, 2])
        assertTrue(result.config.menuBarItems[1].run.flatten().first is FlattenWorkspaceTreeCommand)
        assertTrue(result.config.menuBarItems[1].run.flatten().last is LayoutCommand)
    }

    func testParsesInlineMenuBarItems() { // The form shown commented-out in default-config.toml
        let result = parseConfig(
            """
            menu-bar-item = [
                { label = 'Balance sizes', run = 'balance-sizes' },
                { label = 'Reset workspace', run = ['flatten-workspace-tree', 'balance-sizes'] },
            ]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.menuBarItems.map(\.label), ["Balance sizes", "Reset workspace"])
        assertEquals(result.config.menuBarItems.map { $0.run.flatten().count }, [1, 2])
    }

    func testMenuBarItemMissingLabel() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            run = 'flatten-workspace-tree'
            """,
        )
        assertEquals(result.strErrors, ["[ERROR] menu-bar-item[0]: 'label' is mandatory key"])
        assertTrue(result.config.menuBarItems.isEmpty)
    }

    func testMenuBarItemEmptyLabel() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            label = ''
            run = 'flatten-workspace-tree'
            """,
        )
        assertEquals(result.strErrors, ["[ERROR] menu-bar-item[0].label: 'label' must not be empty"])
        assertTrue(result.config.menuBarItems.isEmpty)
    }

    func testMenuBarItemMissingRun() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            label = 'Foo'
            """,
        )
        assertEquals(result.strErrors, ["[ERROR] menu-bar-item[0]: 'run' is mandatory key"])
        assertTrue(result.config.menuBarItems.isEmpty)
    }

    func testMenuBarItemUnknownKey() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            label = 'Foo'
            run = 'flatten-workspace-tree'

            [[menu-bar-item]]
            label = 'Bar'
            run = 'flatten-workspace-tree'
            shortcut = 'b'
            """,
        )
        assertEquals(result.strErrors, ["[ERROR] menu-bar-item[1].shortcut: Unknown key"])
        // The valid item survives, the broken one is dropped
        assertEquals(result.config.menuBarItems.map(\.label), ["Foo"])
    }

    func testMenuBarItemWrongTypes() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            label = 1
            run = 1
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] menu-bar-item[0].label: Expected type is 'String'. But actual type is 'Int'",
            "[ERROR] menu-bar-item[0].run: Expected types are 'string' or 'array'. But actual type is 'int'",
        ])
        assertTrue(result.config.menuBarItems.isEmpty)

        let notArray = parseConfig("menu-bar-item = 1")
        assertEquals(notArray.strErrors, ["[ERROR] menu-bar-item: Expected type is 'Array'. But actual type is 'Int'"])
    }

    func testMenuBarItemInvalidCommand() {
        let result = parseConfig(
            """
            [[menu-bar-item]]
            label = 'Foo'
            run = 'no-such-command'
            """,
        )
        assertEquals(result.strErrors, ["[ERROR] menu-bar-item[0].run: Unrecognized subcommand 'no-such-command'"])
        assertTrue(result.config.menuBarItems.isEmpty)
    }

    func testRunMenuBarItemChangesTree() async {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
        }
        assertEquals(workspace.focusWorkspace(), true)

        let item = parseConfig(
            """
            [[menu-bar-item]]
            label = 'Flatten'
            run = ['flatten-workspace-tree', 'layout --root v_tiles']
            """,
        ).config.menuBarItems.singleOrNil().orDie()

        // runMenuBarItem wraps this in runLightSession, whose layout pass force-casts windows to MacWindow
        // and traps on TestWindow, so the command sequence is exercised directly here
        await runMenuBarItemCommands(item)
        workspace.normalizeContainers()
        assertEquals(workspace.layoutDescription, .workspace([.v_tiles([.window(1), .window(2)])]))
    }
}
