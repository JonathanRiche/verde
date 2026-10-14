package dev.verdeai.app

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material.icons.Icons
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.filled.Menu
import kotlinx.coroutines.launch
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
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
    const val CHANGES = "changes/{ws}"
    const val FILES = "files/{ws}"
    /** One changed file of the Changes list: repository root and repo-relative path, each one encoded segment. */
    const val PATCH = "patch/{ws}/{root}/{path}"
    fun changes(ws: String) = "changes/${Uri.encode(ws)}"
    fun files(ws: String) = "files/${Uri.encode(ws)}"
    fun patch(ws: String, root: String, path: String) = "patch/${Uri.encode(ws)}/${Uri.encode(root)}/${Uri.encode(path)}"
    /** A Files-tab file: root id and root-relative path; `abs` is the informational host path (may be empty). */
    const val WORKSPACE_FILE = "wfile/{ws}/{root}/{path}?abs={abs}"
    fun workspaceFile(ws: String, root: String, path: String, absolute: String) =
        "wfile/${Uri.encode(ws)}/${Uri.encode(root)}/${Uri.encode(path)}?abs=${Uri.encode(absolute)}"
    fun workspace(ws: String) = "workspace/${Uri.encode(ws)}"
    fun thread(ws: String, thread: String) = "thread/${Uri.encode(ws)}/${Uri.encode(thread)}"
    fun terminal(ws: String, terminal: String) = "terminal/${Uri.encode(ws)}/${Uri.encode(terminal)}"
    fun newTerminal(ws: String) = "terminal-new/${Uri.encode(ws)}"
    fun file(ws: String, citation: FileCitation) =
        "file/${Uri.encode(ws)}/${citation.line ?: 0UL}/${citation.end_line ?: 0UL}/${Uri.encode(citation.path)}"
}

private val TABS = listOf(Routes.HOME, Routes.WORKSPACES, Routes.HOSTS)

/** App shell: workspace drawer over one NavHost. Every browse screen reads only the selected host's core. */
@Composable
internal fun VerdeApp(hosts: HostsModel, browse: BrowseModel, clock: UiClock = remember { UiClock() },
    lock: AppLockControls? = null, push: PushControls? = null) {
    val hostsState by hosts.state.collectAsState()
    val gitBinding: GitChangesBinding = viewModel(factory = viewModelFactory { initializer { GitChangesBinding(hosts, browse.state) } })
    val gitClient by gitBinding.client.collectAsState()
    VerdeTheme {
        AppearanceSystemBars()
        CompositionLocalProvider(LocalUiClock provides clock, LocalAppLockControls provides lock, LocalGitChangesClient provides gitClient,
            LocalPushControls provides push) {
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
    // Terminals keep the full height and their own back bar.
    val immersive = route == Routes.TERMINAL || route == Routes.NEW_TERMINAL
    // Highlight only actual root destinations; detail routes select their own row.
    val currentTab = route?.takeIf { r -> r in TABS }.orEmpty()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val browseState by browse.state.collectAsState()
    val manage: ManageModel = viewModel(key = "manage", factory = viewModelFactory { initializer { ManageModel(hosts, browse.state) } })
    val manageState by manage.state.collectAsState()
    val companion: CompanionModel = viewModel(key = "companion", factory = viewModelFactory { initializer { CompanionModel(hosts, browse.state) } })
    var threadAction by remember { mutableStateOf<Pair<ThreadSummary, String>?>(null) }
    fun open(route: String, tab: Boolean = false) {
        if (tab) nav.tab(route) else nav.navigate(route) { launchSingleTop = true }
        scope.launch { drawer.close() }
    }
    threadAction?.let { (thread, action) ->
        key(browseState.hostId, thread.workspace_id, thread.thread_id, action) {
            ThreadActionDialog(thread, action, manage, onDismiss = { threadAction = null }, onClosed = {
                threadAction = null
                if (entry?.arguments?.getString("thread") == thread.thread_id &&
                    entry?.arguments?.getString("ws") == thread.workspace_id) open(Routes.HOME, tab = true)
            })
        }
    }
    // D-14: a notification opens its thread once its host is the selected one.
    LocalPushControls.current?.let { push ->
        val link by push.links.collectAsState()
        LaunchedEffect(link, hostsState.active) {
            val target = link ?: return@LaunchedEffect
            if (target.hostId != hostsState.active) return@LaunchedEffect
            push.consumeLink(target)
            nav.navigate(Routes.thread(target.workspaceId, target.threadId)) { launchSingleTop = true }
            drawer.close()
        }
        PushOptInPrompt(hostsState)
    }
    // Sidebar scope: null is All Workspaces. It filters the drawer only and resets per host.
    var workspaceScope by rememberSaveable(browseState.hostId) { mutableStateOf<String?>(null) }
    LaunchedEffect(browseState.hostId) { threadAction = null }
    LaunchedEffect(browseState.workspaces?.items?.map { it.workspace_id }) {
        val ids = browseState.workspaces?.items?.map { it.workspace_id } ?: return@LaunchedEffect
        if (workspaceScope != null && workspaceScope !in ids) workspaceScope = null
    }
    // Machine Companion: a draggable bubble over every main screen, opening a sheet.
    CompanionVisibility(companion)
    val companionState by companion.state.collectAsState()
    // Reset per host; survives rotation.
    var companionOpen by rememberSaveable(browseState.hostId) { mutableStateOf(false) }
    var companionSettings by rememberSaveable(browseState.hostId) { mutableStateOf(false) }
    val companionNow = companionSnapshot(companionState, browseState)
    val companionActive = companionNow.active
    val onCompanionThread = route == Routes.THREAD && companionActive != null && companionActive.thread_id.isNotEmpty() &&
        entry?.arguments?.getString("thread") == companionActive.thread_id && entry?.arguments?.getString("ws") == companionActive.home_workspace_id
    val drawerOpen = drawer.isOpen || drawer.targetValue == DrawerValue.Open
    val bubbleContext = LocalContext.current
    val bubblePrefs = remember(bubbleContext) { BubblePrefs.of(bubbleContext) }
    fun leaveCompanion(route: String, tab: Boolean = false) { companionOpen = false; open(route, tab) }
    // Companion voice: one recognizer/TTS for the activity, and the companion chat's model shared
    // by the bubble's hold-to-talk and the sheet.
    val voiceContext = bubbleContext.applicationContext
    val voice: CompanionVoice = viewModel(key = "companion-voice", factory = viewModelFactory { initializer { CompanionVoice(voiceContext) } })
    val companionTranscript: TranscriptModel? = companionActive?.takeIf { companionState.available && it.thread_id.isNotEmpty() }?.let { a ->
        viewModel<TranscriptModel>(key = "companion:${browseState.hostId}:${a.home_workspace_id}:${a.thread_id}",
            factory = viewModelFactory { initializer { TranscriptModel(hosts, browse.state, a.home_workspace_id, a.thread_id) } })
    }
    LaunchedEffect(voice, companionTranscript) { voice.attach(companionTranscript) }
    // Real-time voice (phase 2): provider WebSocket from the phone, token minted by the desktop.
    val live: LiveVoice = viewModel(key = "companion-live", factory = viewModelFactory { initializer { LiveVoice(voiceContext, hosts, browse.state, companion) } })
    val liveUi by live.ui.collectAsState()
    val liveLevel by live.outputLevel.collectAsState()
    val liveInput by live.inputLevel.collectAsState()
    val liveView by live.voice.collectAsState()
    SideEffect {
        live.companionTranscript = companionTranscript
        live.snapshot = { companionSnapshot(companion.state.value, browse.state.value) }
        live.workspaceLabel = { ws -> browse.state.value.workspaces?.items?.find { it.workspace_id == ws }?.label }
    }
    LaunchedEffect(liveUi.active) { voice.suppressed = liveUi.active }
    val voiceActive by voice.active.collectAsState()
    LaunchedEffect(voice, companionTranscript, voiceActive, liveUi.active, companionOpen) {
        voice.holdFocus(companionTranscript, voiceActive || liveUi.active, companionOpen)
    }
    // Opening another chat stops a reply being read aloud.
    val openThread = entry?.arguments?.getString("thread")
    LaunchedEffect(route, openThread) { if (route == Routes.THREAD && !onCompanionThread) voice.stopSpeaking() }
    val shellLifecycle by androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val mic = rememberMicPermission()
    LaunchedEffect(shellLifecycle) {
        if (!shellLifecycle.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)) { voice.pause(); live.stop() }
    }
    fun toggleLive() {
        when {
            live.ui.value.active -> live.stop()
            !mic.granted() -> mic.request()
            else -> { voice.pause(); live.start() }
        }
    }
    val talkState by voice.talk.collectAsState()
    val talkLevel by voice.level.collectAsState()
    val talkSpeaking by voice.speaking.collectAsState()
    val talkError by voice.error.collectAsState()
    // Companion conversations stay behind the bubble: chat lists leave them out.
    val companionThreads = remember(companionState.roster) { companionThreadIds(companionState.roster) }
    CompositionLocalProvider(LocalHiddenThreads provides companionThreads) {
    Box(Modifier.fillMaxSize()) {
    ModalNavigationDrawer(drawerState = drawer, gesturesEnabled = !pairing && !immersive,
        drawerContent = {
            WorkspaceDrawer(browseState, currentTab, visible = drawer.isOpen || drawer.targetValue == DrawerValue.Open, onClose = { scope.launch { drawer.close() } },
                onTab = { open(it, tab = true) },
                onThread = { ws, thread -> open(Routes.thread(ws, thread)) },
                onHistory = { open(ManageRoutes.HISTORY) },
                scope = workspaceScope, onScope = { workspaceScope = it }, onNewChat = { open(ManageRoutes.newChat(it)) },
                selectedWorkspace = entry?.arguments?.getString("ws"), selectedThread = entry?.arguments?.getString("thread"),
                selectedTerminal = entry?.arguments?.getString("terminal"),
                onTerminal = { ws, terminal -> open(Routes.terminal(ws, terminal)) },
                onNewTerminal = { open(Routes.newTerminal(it)) },
                onAddWorkspace = { open(ManageRoutes.ADD_WORKSPACE) },
                onWorkspaceSettings = { open(Routes.workspace(it)) },
                onSettings = LocalAppLockControls.current?.let { { open(Routes.SECURITY) } },
                onChanges = { open(Routes.changes(it)) }, onFiles = { open(Routes.files(it)) },
                canManageWorkspaces = manageState.view?.can_manage_workspaces == true,
                onReopen = { manage.setArchived(it, false) },
                canEditThreads = manageState.view?.can_create_threads == true,
                onThreadAction = { thread, action -> scope.launch {
                    drawer.close()
                    threadAction = thread to action
                } })
        }) {
        Scaffold(
            contentWindowInsets = WindowInsets.safeDrawing,
            topBar = {
                if (!pairing && route in TABS) Box(Modifier.background(VerdeColors.Panel).statusBarsPadding()) {
                    VerdeTopBar(title = { VerdeWordmark() },
                        navigationIcon = { IconButton(onClick = { scope.launch { drawer.open() } }) {
                            Icon(Icons.Filled.Menu, contentDescription = "Open workspace drawer")
                        } }, actions = {
                            HostSwitcher(hosts,
                                // Hosts lists the machines; after a switch, land on the new host's Home.
                                onSwitched = { if (nav.currentDestination?.route == Routes.HOSTS) nav.tab(Routes.HOME) },
                                onPairing = { nav.tab(Routes.HOSTS) })
                        })
                }
            },
        ) { padding ->
            Box(Modifier.padding(padding).consumeWindowInsets(padding)) {
                CompositionLocalProvider(LocalWorkspaceMenu provides { scope.launch { drawer.open() }; Unit }) {
                    Graph(nav, start, hosts, browse, manage) { thread, action -> threadAction = thread to action }
                }
            }
        }
    }
    if (companionState.available) {
        val character = CompanionCharacter.of(companionActive?.character)
        val name = companionActive?.name?.ifBlank { null } ?: character.label
        val online = browseState.host?.phase == "ready" && browseState.networkAvailable
        val thread = companionNow.companionThread
        CompanionBubbleLayer(
            shown = !companionOpen && !onCompanionThread && !pairing && !immersive && !drawerOpen && !hostsState.loading &&
                !bubblePrefs.hidden,
            hostId = browseState.hostId, name = name, character = character,
            pose = companionPose(online, companionNow.needKeys.isNotEmpty(), companionNow.crewRunning),
            needKeys = companionNow.needKeys, running = companionNow.crewRunning,
            replyAt = thread?.takeIf { !activeTurn(it.status) }?.last_activity_at_ms,
            replyText = { companionActive?.let { companion.latestReply(it.home_workspace_id, it.thread_id) } },
            live = if (liveView?.supported == false) null else BubbleLive(liveUi.active, maxOf(liveLevel, liveInput),
                liveUi.captions.lastOrNull()?.text, ::toggleLive),
            talk = if (!voice.available || liveUi.active) null else BubbleTalk(talkState, talkLevel, talkSpeaking, talkError,
                start = {
                    val model = companionTranscript
                    when {
                        // No conversation yet: the sheet sets one up first.
                        model == null -> { companionSettings = false; companionOpen = true; false }
                        !mic.granted() -> { mic.request(); false }
                        else -> { voice.press(model, liveDraft = false); true }
                    }
                },
                move = voice::move, release = voice::release, cancel = voice::cancel,
                stopSpeaking = voice::stopSpeaking, clearError = voice::clearError),
            onOpen = { companionSettings = false; companionOpen = true })
    }
    }
    }
    if (companionOpen && companionState.available) {
        CompanionSheet(hosts, browse, manage, companion,
            onOpenPane = { pane ->
                val paneThread = pane.thread_id
                val terminal = pane.terminal_id
                if (pane.kind == "chat" && paneThread != null) leaveCompanion(Routes.thread(pane.workspace_id, paneThread))
                else if (pane.kind == "terminal" && terminal != null) leaveCompanion(Routes.terminal(pane.workspace_id, terminal))
            },
            onOpenChat = { ws, chat -> leaveCompanion(Routes.thread(ws, chat)) },
            onActivity = { leaveCompanion(Routes.HOME, tab = true) },
            onCitation = { ws, citation -> leaveCompanion(Routes.file(ws, citation)) },
            settingsRequested = companionSettings,
            transcript = companionTranscript, voice = voice,
            onHideBubble = { bubblePrefs.updateHidden(true) },
            live = live, onLive = ::toggleLive,
            onDismiss = { companionOpen = false; companionSettings = false })
    }
}

private fun NavHostController.tab(route: String) = navigate(route) {
    // Drawer destinations always open their root, never a saved nested chat.
    popUpTo(graph.findStartDestination().id) { saveState = false }
    launchSingleTop = true
    restoreState = false
}

@Composable
private fun Graph(nav: NavHostController, start: String, hosts: HostsModel, browse: BrowseModel, manage: ManageModel,
    onThreadAction: (ThreadSummary, String) -> Unit) {
    val openPane: (Pane) -> Unit = { pane ->
        val thread = pane.thread_id
        val terminal = pane.terminal_id
        if (pane.kind == "chat" && thread != null) nav.navigate(Routes.thread(pane.workspace_id, thread))
        else if (pane.kind == "terminal" && terminal != null) nav.navigate(Routes.terminal(pane.workspace_id, terminal))
    }
    val openThread: (ThreadSummary) -> Unit = { nav.navigate(Routes.thread(it.workspace_id, it.thread_id)) }
    val openWorkspace: (String) -> Unit = { nav.navigate(Routes.workspace(it)) }
    val showHosts: () -> Unit = { nav.tab(Routes.HOSTS) }
    val openFile: (String, FileCitation) -> Unit = { ws, citation -> nav.navigate(Routes.file(ws, citation)) }
    val openAsked: (String, String) -> Unit = { ws, thread -> nav.navigate(Routes.thread(ws, thread)) }
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
                    ExplorerLinks(onChanges = { nav.navigate(Routes.changes(workspace.workspace_id)) }, onFiles = { nav.navigate(Routes.files(workspace.workspace_id)) },
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                    WorkspaceActions(state, manage, workspace) { nav.navigate(ManageRoutes.newChat(workspace.workspace_id)) }
                }) { nav.popBackStack() }
        }
        manageRoutes(nav, browse, manage, openThread, openWorkspace)
        composable(Routes.THREAD) { entry ->
            val args = entry.arguments
            val ws = args?.getString("ws").orEmpty()
            ThreadRoute(hosts, browse, manage, ws, args?.getString("thread").orEmpty(), showHosts, onCitation = { openFile(ws, it) }, onThreadAction = onThreadAction,
                onOpenThread = { nav.navigate(Routes.thread(ws, it)) }) { nav.popBackStack() }
        }
        composable(Routes.TERMINAL) { entry ->
            val args = entry.arguments
            TerminalScreen(hosts, browse, args?.getString("ws").orEmpty(), args?.getString("terminal").orEmpty()) { nav.popBackStack() }
        }
        composable(Routes.FILE) { entry ->
            val args = entry.arguments
            val ws = args?.getString("ws").orEmpty()
            SelectableFileRoute(hosts, browse, ws, args?.getString("path").orEmpty(),
                args?.getString("line")?.toLongOrNull()?.takeIf { it > 0 }, args?.getString("end")?.toLongOrNull()?.takeIf { it > 0 },
                onCitation = { openFile(ws, it) }, onOpenThread = openAsked) { nav.popBackStack() }
        }
        composable(Routes.CHANGES) { entry ->
            val ws = entry.arguments?.getString("ws").orEmpty()
            ChangesRoute(hosts, browse, ws, onOpenPatch = { root, path -> nav.navigate(Routes.patch(ws, root, path)) }) { nav.popBackStack() }
        }
        composable(Routes.FILES) { entry ->
            val ws = entry.arguments?.getString("ws").orEmpty()
            FilesRoute(hosts, browse, ws, onOpenFile = { root, path ->
                nav.navigate(Routes.workspaceFile(ws, root.id, path, root.absolute(path).orEmpty()))
            }) { nav.popBackStack() }
        }
        composable(Routes.WORKSPACE_FILE, arguments = listOf(navArgument("abs") { defaultValue = "" })) { entry ->
            val args = entry.arguments
            val ws = args?.getString("ws").orEmpty()
            WorkspaceFileRoute(hosts, browse, ws, args?.getString("root").orEmpty(), args?.getString("path").orEmpty(), args?.getString("abs").orEmpty(),
                onCitation = { openFile(ws, it) }, onOpenThread = openAsked) { nav.popBackStack() }
        }
        composable(Routes.PATCH) { entry ->
            val args = entry.arguments
            val ws = args?.getString("ws").orEmpty()
            PatchRoute(hosts, browse, ws, args?.getString("root").orEmpty(), args?.getString("path").orEmpty(),
                onOpenFile = { openFile(ws, it) }, onOpenThread = openAsked) { nav.popBackStack() }
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
