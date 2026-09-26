package dev.verdeai.app

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.verdeai.core.FileCitation
import dev.verdeai.core.Pane
import dev.verdeai.core.ThreadSummary

internal object Routes {
    const val HOME = "home"
    const val WORKSPACES = "workspaces"
    const val HOSTS = "hosts"
    const val WORKSPACE = "workspace/{ws}"
    const val THREAD = "thread/{ws}/{thread}"
    const val TERMINAL = "terminal/{ws}/{terminal}"
    const val NEW_TERMINAL = "terminal-new/{ws}"
    /** D-12 viewer; the path is one encoded segment and 0 means "no line". */
    const val FILE = "file/{ws}/{line}/{end}/{path}"
    const val SECURITY = "settings/security"
    fun workspace(ws: String) = "workspace/${Uri.encode(ws)}"
    fun thread(ws: String, thread: String) = "thread/${Uri.encode(ws)}/${Uri.encode(thread)}"
    fun terminal(ws: String, terminal: String) = "terminal/${Uri.encode(ws)}/${Uri.encode(terminal)}"
    fun newTerminal(ws: String) = "terminal-new/${Uri.encode(ws)}"
    fun file(ws: String, citation: FileCitation) =
        "file/${Uri.encode(ws)}/${citation.line ?: 0UL}/${citation.end_line ?: 0UL}/${Uri.encode(citation.path)}"
}

private data class Tab(val route: String, val label: String, val icon: ImageVector)
private val TABS = listOf(Tab(Routes.HOME, "Home", Icons.Filled.Home),
    Tab(Routes.WORKSPACES, "Workspaces", Icons.AutoMirrored.Filled.List), Tab(Routes.HOSTS, "Hosts", Icons.Filled.Settings))

/** App shell: bottom tabs over one NavHost. Every browse screen reads only the selected host's core. */
@Composable
internal fun VerdeApp(hosts: HostsModel, browse: BrowseModel, clock: UiClock = remember { UiClock() },
    lock: AppLockControls? = null) {
    val hostsState by hosts.state.collectAsState()
    MaterialTheme {
        CompositionLocalProvider(LocalUiClock provides clock, LocalAppLockControls provides lock) {
            val app = @Composable { if (hostsState.loading) HostsScreen(hosts) else Shell(hosts, browse, hostsState) }
            if (lock != null) AppLockGate(lock.model, lock.auth, app) else app()
        }
    }
}

@Composable
private fun Shell(hosts: HostsModel, browse: BrowseModel, hostsState: HostsState) {
    val nav = rememberNavController()
    val start = remember { if (hostsState.active != null) Routes.HOME else Routes.HOSTS }
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    val pairing = hostsState.pairing != null && route == Routes.HOSTS
    // Terminals need the full height, and the tab bar would otherwise hide IME insets.
    val immersive = route == Routes.TERMINAL || route == Routes.NEW_TERMINAL
    // Detail routes keep the tab they were opened from highlighted.
    var lastTab by rememberSaveable { mutableStateOf(start) }
    LaunchedEffect(route) { if (TABS.any { it.route == route }) lastTab = route!! }
    val currentTab = route?.takeIf { r -> TABS.any { it.route == r } } ?: lastTab
    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        bottomBar = {
            if (!pairing && !immersive) NavigationBar {
                TABS.forEach { tab ->
                    NavigationBarItem(selected = currentTab == tab.route, onClick = { nav.tab(tab.route) },
                        icon = { Icon(tab.icon, contentDescription = null) },
                        label = { Text(tab.label, textAlign = TextAlign.Center) })
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).consumeWindowInsets(padding)) {
            Graph(nav, start, hosts, browse)
        }
    }
}

private fun NavHostController.tab(route: String) = navigate(route) {
    popUpTo(graph.findStartDestination().id) { saveState = true }
    launchSingleTop = true
    restoreState = true
}

@Composable
private fun Graph(nav: NavHostController, start: String, hosts: HostsModel, browse: BrowseModel) {
    val openPane: (Pane) -> Unit = { pane ->
        val thread = pane.thread_id
        val terminal = pane.terminal_id
        if (pane.kind == "chat" && thread != null) nav.navigate(Routes.thread(pane.workspace_id, thread))
        else if (pane.kind == "terminal" && terminal != null) nav.navigate(Routes.terminal(pane.workspace_id, terminal))
    }
    val openThread: (ThreadSummary) -> Unit = { nav.navigate(Routes.thread(it.workspace_id, it.thread_id)) }
    val openWorkspace: (String) -> Unit = { nav.navigate(Routes.workspace(it)) }
    val showHosts: () -> Unit = { nav.tab(Routes.HOSTS) }
    val manage: ManageModel = viewModel(key = "manage", factory = viewModelFactory { initializer { ManageModel(hosts, browse.state) } })
    val openFile: (String, FileCitation) -> Unit = { ws, citation -> nav.navigate(Routes.file(ws, citation)) }
    val pair: () -> Unit = {
        browse.state.value.hostId?.let { id -> if (browse.state.value.row?.view?.auth_state != "signing_out") hosts.showPairing(id) }
        nav.tab(Routes.HOSTS)
    }
    NavHost(nav, startDestination = start) {
        composable(Routes.HOME) {
            HomeScreen(browse, openPane, openThread, openWorkspace, showHosts, pair,
                onNewChat = { nav.navigate(ManageRoutes.newChat(null)) }, onHistory = { nav.navigate(ManageRoutes.HISTORY) })
        }
        composable(Routes.WORKSPACES) { WorkspacesScreen(browse, openWorkspace, showHosts, pair) { nav.navigate(ManageRoutes.ADD_WORKSPACE) } }
        composable(Routes.HOSTS) {
            val security = LocalAppLockControls.current?.let { { nav.navigate(Routes.SECURITY) } }
            HostsScreen(hosts, onUse = { nav.tab(Routes.HOME) }, onSecurity = security)
        }
        composable(Routes.SECURITY) {
            LocalAppLockControls.current?.let { SecuritySettingsScreen(it.model, it.auth) { nav.popBackStack() } }
        }
        composable(Routes.WORKSPACE) { entry ->
            val ws = entry.arguments?.getString("ws").orEmpty()
            WorkspaceScreen(browse, ws, openPane, openThread, showHosts, pair, onNewTerminal = { nav.navigate(Routes.newTerminal(ws)) },
                actions = { workspace ->
                    val state by browse.state.collectAsState()
                    WorkspaceActions(state, manage, workspace) { nav.navigate(ManageRoutes.newChat(workspace.workspace_id)) }
                }) { nav.popBackStack() }
        }
        manageRoutes(nav, browse, manage, openThread, openWorkspace)
        composable(Routes.THREAD) { entry ->
            val args = entry.arguments
            val ws = args?.getString("ws").orEmpty()
            ThreadRoute(hosts, browse, ws, args?.getString("thread").orEmpty(), showHosts, onCitation = { openFile(ws, it) }) { nav.popBackStack() }
        }
        composable(Routes.TERMINAL) { entry ->
            val args = entry.arguments
            TerminalScreen(hosts, browse, args?.getString("ws").orEmpty(), args?.getString("terminal").orEmpty()) { nav.popBackStack() }
        }
        composable(Routes.FILE) { entry ->
            val args = entry.arguments
            val ws = args?.getString("ws").orEmpty()
            FileRoute(hosts, browse, ws, args?.getString("path").orEmpty(),
                args?.getString("line")?.toLongOrNull()?.takeIf { it > 0 }, args?.getString("end")?.toLongOrNull()?.takeIf { it > 0 },
                onCitation = { openFile(ws, it) }) { nav.popBackStack() }
        }
        composable(Routes.NEW_TERMINAL) { entry ->
            TerminalScreen(hosts, browse, entry.arguments?.getString("ws").orEmpty(), null) { nav.popBackStack() }
        }
    }
}

/** D-10 history, new chat and add-workspace routes. A created chat replaces the form in the back stack. */
private fun androidx.navigation.NavGraphBuilder.manageRoutes(nav: NavHostController, browse: BrowseModel, manage: ManageModel,
    openThread: (ThreadSummary) -> Unit, openWorkspace: (String) -> Unit) {
    composable(ManageRoutes.HISTORY) { HistoryScreen(browse, manage, openThread) { nav.popBackStack() } }
    val created: (String, String) -> Unit = { ws, thread ->
        nav.navigate(Routes.thread(ws, thread)) { popUpTo(nav.currentBackStackEntry?.destination?.id ?: 0) { inclusive = true } }
    }
    composable(ManageRoutes.NEW_CHAT) { NewChatScreen(browse, manage, null, created) { nav.popBackStack() } }
    composable(ManageRoutes.NEW_CHAT_IN) { entry ->
        NewChatScreen(browse, manage, entry.arguments?.getString("ws"), created) { nav.popBackStack() }
    }
    composable(ManageRoutes.ADD_WORKSPACE) {
        AddWorkspaceScreen(browse, manage, onCreated = { ws ->
            nav.navigate(Routes.workspace(ws)) { popUpTo(ManageRoutes.ADD_WORKSPACE) { inclusive = true } }
        }) { nav.popBackStack() }
    }
}
