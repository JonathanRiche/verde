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
    fun workspace(ws: String) = "workspace/${Uri.encode(ws)}"
    fun thread(ws: String, thread: String) = "thread/${Uri.encode(ws)}/${Uri.encode(thread)}"
    fun terminal(ws: String, terminal: String) = "terminal/${Uri.encode(ws)}/${Uri.encode(terminal)}"
    fun newTerminal(ws: String) = "terminal-new/${Uri.encode(ws)}"
}

private data class Tab(val route: String, val label: String, val icon: ImageVector)
private val TABS = listOf(Tab(Routes.HOME, "Home", Icons.Filled.Home),
    Tab(Routes.WORKSPACES, "Workspaces", Icons.AutoMirrored.Filled.List), Tab(Routes.HOSTS, "Hosts", Icons.Filled.Settings))

/** App shell: bottom tabs over one NavHost. Every browse screen reads only the selected host's core. */
@Composable
internal fun VerdeApp(hosts: HostsModel, browse: BrowseModel, clock: UiClock = remember { UiClock() }) {
    val hostsState by hosts.state.collectAsState()
    MaterialTheme {
        CompositionLocalProvider(LocalUiClock provides clock) {
            if (hostsState.loading) HostsScreen(hosts) else Shell(hosts, browse, hostsState)
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
    val pair: () -> Unit = {
        browse.state.value.hostId?.let { id -> if (browse.state.value.row?.view?.auth_state != "signing_out") hosts.showPairing(id) }
        nav.tab(Routes.HOSTS)
    }
    NavHost(nav, startDestination = start) {
        composable(Routes.HOME) { HomeScreen(browse, openPane, openThread, openWorkspace, showHosts, pair) }
        composable(Routes.WORKSPACES) { WorkspacesScreen(browse, openWorkspace, showHosts, pair) }
        composable(Routes.HOSTS) { HostsScreen(hosts, onUse = { nav.tab(Routes.HOME) }) }
        composable(Routes.WORKSPACE) { entry ->
            val ws = entry.arguments?.getString("ws").orEmpty()
            WorkspaceScreen(browse, ws, openPane, openThread, showHosts, pair, onNewTerminal = { nav.navigate(Routes.newTerminal(ws)) }) { nav.popBackStack() }
        }
        composable(Routes.THREAD) { entry ->
            val args = entry.arguments
            ThreadRoute(hosts, browse, args?.getString("ws").orEmpty(), args?.getString("thread").orEmpty(), showHosts) { nav.popBackStack() }
        }
        composable(Routes.TERMINAL) { entry ->
            val args = entry.arguments
            TerminalScreen(hosts, browse, args?.getString("ws").orEmpty(), args?.getString("terminal").orEmpty()) { nav.popBackStack() }
        }
        composable(Routes.NEW_TERMINAL) { entry ->
            TerminalScreen(hosts, browse, entry.arguments?.getString("ws").orEmpty(), null) { nav.popBackStack() }
        }
    }
}
