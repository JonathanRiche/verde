package dev.verdeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.activity.ComponentActivity
import org.junit.Before
import org.robolectric.Shadows
import org.robolectric.shadows.ShadowDisplay
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import dev.verdeai.core.ChatRow
import androidx.lifecycle.ViewModelStore
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Synthetic protocol-shaped fixtures only. No repository commands or live providers. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-mdpi")
// Native text metrics and dialog hit testing are required for real sheet taps.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class GitChangesTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Before fun phoneWindow() {
        Shadows.shadowOf(ShadowDisplay.getDefaultDisplay()).apply {
            setWidth(411); setHeight(891); setRealWidth(411); setRealHeight(891); setDensity(1f)
        }
        compose.activity.window.setLayout(411, 891)
    }
    private val models = ViewModelStore()
    @After fun closeModels() { models.clear() }
    private val chat = GitChat("workspace", "thread")
    private val mine = GitFile("app.kt", additions = 2, deletions = 1, hunkSelectable = true, hunks = listOf(
        GitHunk(0, "@@ -1 +1 @@", "@@ -1 +1 @@\n-before\n+after"),
        GitHunk(1, "@@ -4 +4 @@", "@@ -4 +4 @@\n+added")))
    private val ownEdits = GitFile("notes.txt", ownership = GitOwnership.Unassigned, additions = 1)
    private fun review(branch: String? = "feature/mobile", files: List<GitFile> = listOf(mine), running: Boolean = false) = GitReview(
        "review-1", chat, running, repos = listOf(GitRepo(GitBranch("/scratch", "scratch", branch, isDefault = branch in setOf("main", "master"), hasRemote = true), "fixture-head", files)))
    private inner class Fake(var review: GitReview = review(), access: GitAccess = GitAccess.Writable) : GitChangesClient {
        override val snapshot = MutableStateFlow(GitSnapshot(
            summaries = mapOf(chat to GitSummary(review.repos.sumOf { it.files.size }, 2, 1, review.repos.flatMap { it.files }.count { it.ownership != GitOwnership.Mine })),
            branches = mapOf(chat to review.repos.map { it.branch }), access = mapOf(chat to access), connected = true))
        val pushedRoots = mutableListOf<String>()
        var refreshes = 0; var reviews = 0; var messages = 0; var commits = 0; var pushes = 0
        var messageGate: CompletableDeferred<Unit>? = null
        var commitGate: CompletableDeferred<Unit>? = null
        var failure: String? = null
        var outcome = GitPush.NotRequested
        var committedMessage: String? = null
        var committedSelections: List<GitSelection>? = null
        var committedPush = false
        var committedNewBranch = false
        var committedBranchName: String? = null
        var checking = false
        var pulled = false
        override suspend fun refresh(chat: GitChat) { refreshes++ }
        override suspend fun review(chat: GitChat, hunkBudgetBytes: Int): GitReview { reviews++; return review.copy(id = "review-$reviews") }
        override suspend fun message(reviewId: String, selections: List<GitSelection>): GitMessage {
            messages++; messageGate?.await(); return GitMessage("Improve mobile flow", "codex", "fast", "feature/mobile-flow")
        }
        override suspend fun commit(reviewId: String, message: String, selections: List<GitSelection>, push: Boolean, newBranch: Boolean, branchName: String?, onChecking: (Boolean) -> Unit): GitCommitResult {
            commits++; committedMessage = message; committedSelections = selections; committedPush = push
            committedNewBranch = newBranch; committedBranchName = branchName
            if (checking) onChecking(true)
            commitGate?.await()
            failure?.let { throw GitFailure(it) }
            return GitCommitResult(listOf(GitRepoCommit("/scratch", "123abcd", selections.sumOf { it.files.size }, outcome)))
        }
        override suspend fun push(chat: GitChat, root: String, pull: Boolean, requestId: String, onChecking: (Boolean) -> Unit): GitPush { pushes++; pushedRoots += root; pulled = pull; return GitPush.Pushed }
    }
    private fun mount(fake: Fake): GitChangesModel {
        val model = GitChangesModel(chat, fake)
        models.put("git", model)
        compose.setContent { VerdeTheme { CompositionLocalProvider(LocalGitChangesClient provides fake) {
            Box(Modifier.fillMaxSize()) { GitChangesHeader(model); GitChangesLayer(model) }
        } } }
        return model
    }
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000, condition)

    @Test fun wholeRowsSelectWithoutEditAndCommitGeneratesForTheSelection() {
        val fake = Fake(review(files = listOf(ownEdits)))
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.review != null }
        compose.onNodeWithContentDescription("Include notes.txt").assertIsOff()
        compose.onNodeWithTag("git-submit").assertIsNotEnabled()
        compose.onNodeWithTag("git-new-branch").assertIsNotEnabled()
        compose.onNodeWithTag("git-file:notes.txt").performClick()
        compose.onNodeWithContentDescription("Include notes.txt").assertIsOn()
        compose.onNodeWithTag("git-submit").assertIsEnabled().performClick()
        await { fake.commits == 1 }
        assertEquals(1, fake.messages)
        assertEquals(listOf(GitSelection("/scratch", listOf(GitFileSelection("notes.txt")))), fake.committedSelections)
    }

    @Test fun bulkDiffToggleDoesNotGateSelectionAndRegeneratesStaleMessage() {
        val fake = Fake(review(files = listOf(mine, ownEdits)))
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generated != null }
        compose.onNodeWithText("Show diffs").performClick()
        compose.onNodeWithContentDescription("Hide diff for app.kt").assertExists()
        compose.onNodeWithTag("git-file:notes.txt").performScrollTo().performClick()
        assertEquals(2, model.state.value.fileCount)
        assertNull(model.state.value.generated)
        compose.onNodeWithText("Hide diffs").performClick()
        await { fake.messages == 2 && model.state.value.generated != null }
        compose.onNodeWithContentDescription("Show diff for app.kt").assertExists()
        compose.onNodeWithTag("git-file:notes.txt").performClick()
        assertEquals(1, model.state.value.fileCount)
        compose.onNodeWithTag("git-submit").performClick()
        await { fake.commits == 1 }
        assertEquals(3, fake.messages)
        assertEquals(listOf(GitSelection("/scratch", listOf(GitFileSelection("app.kt")))), fake.committedSelections)
    }

    @Test fun sheetHasBranchFilesPlaceholderAndExplicitHunkSelection() {
        val fake = Fake(review("main", listOf(mine, ownEdits)))
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generated != null }
        compose.onNodeWithText("Commit changes").assertIsDisplayed()
        compose.onNodeWithText("Default branch").assertIsDisplayed()
        compose.onNodeWithTag("git-message").assertTextContains("Improve mobile flow")
        assertEquals("", model.state.value.typedMessage)
        assertEquals(listOf(GitSelection("/scratch", listOf(GitFileSelection("app.kt")))), model.state.value.selections)
        compose.onNodeWithContentDescription("Include notes.txt").assertIsOff()
        compose.onNodeWithContentDescription("Show diff for app.kt").performClick()
        compose.onNodeWithContentDescription("Include hunk 2 of app.kt").performScrollTo().performClick()
        assertEquals(listOf(0), model.state.value.selections.single().files.single().hunks)
        assertEquals(1 to 1, model.state.value.totals)
        compose.onNodeWithTag("git-message").performTextInput("My precise message")
        compose.onNodeWithTag("git-submit").assertIsDisplayed().assertIsEnabled().performClick()
        await { fake.commits == 1 && !model.state.value.busy }
        assertEquals("My precise message", fake.committedMessage)
        assertFalse(fake.committedPush)
        assertEquals(listOf(0), fake.committedSelections!!.single().files.single().hunks)
    }

    @Test fun mainQuickActionWaitsForConfirmationAndGeneratedSubject() {
        val fake = Fake(review("main")); fake.outcome = GitPush.Pushed
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.generated != null }
        compose.onNodeWithText("Commit & push to main?").assertIsDisplayed()
        compose.onNodeWithText("1 file · Improve mobile flow").assertIsDisplayed()
        compose.onNodeWithText("Create branch & continue").assertIsEnabled()
        assertEquals(0, fake.commits)
        compose.onNodeWithTag("git-confirm-main").performClick()
        await { fake.commits == 1 && !model.state.value.busy }
        assertTrue(fake.committedPush)
        assertEquals("Improve mobile flow", fake.committedMessage)
        compose.onNodeWithText("Committed & pushed 1 file").assertIsDisplayed()
    }

    @Test fun featureQuickActionCommitsExactlyOnceWithoutSheet() {
        val fake = Fake(); fake.commitGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true); model.open(GitAction.CommitAndPush, true) }
        await { fake.commits == 1 }
        compose.onNodeWithTag("git-sheet").assertDoesNotExist()
        compose.runOnIdle { model.commit(); model.dismiss() }
        assertEquals(1, fake.commits)
        compose.runOnIdle { fake.commitGate!!.complete(Unit) }
        await { !model.state.value.busy }
    }

    @Test fun noMineOpensReviewButRunningMineUsesQuickCommit() {
        val fake = Fake(review(files = listOf(mine.copy(ownership = GitOwnership.Shared))))
        val model = mount(fake)
        for (ownership in listOf(GitOwnership.Shared, GitOwnership.Unclear, GitOwnership.Unassigned)) {
            compose.runOnIdle { fake.review = review(files = listOf(mine.copy(ownership = ownership))); model.open(GitAction.CommitAndPush, true) }
            await { !model.state.value.loading }
            compose.onNodeWithTag("git-sheet").assertIsDisplayed()
            assertEquals(0, fake.commits)
            if (ownership == GitOwnership.Unassigned) assertEquals(0, model.state.value.fileCount)
            compose.runOnIdle { model.dismiss() }
        }
        compose.runOnIdle { fake.review = review(running = true); model.open(GitAction.CommitAndPush, true) }
        await { !model.state.value.loading }
        await { fake.commits == 1 }
        assertEquals(listOf(GitSelection("/scratch", listOf(GitFileSelection("app.kt")))), fake.committedSelections)
    }

    @Test fun rejectedPushKeepsCommitAndOffersExplicitPullPush() {
        val fake = Fake(); fake.outcome = GitPush.Rejected
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.notice?.phase == GitResultPhase.Failure }
        compose.onNodeWithText("Committed 1 file").assertIsDisplayed()
        assertEquals(0, fake.pushes)
        compose.onNodeWithText("Pull & push").performClick()
        await { fake.pushes == 1 && !model.state.value.busy }
        assertTrue(fake.pulled)
        assertEquals(1, fake.commits)
        assertTrue(model.state.value.rejectedRoots.isEmpty())
    }

    @Test fun changedReviewRefreshesWithoutRetryingCommit() {
        val fake = Fake(); fake.failure = "changed_since_review"
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { fake.reviews == 2 && !model.state.value.loading }
        assertEquals(1, fake.commits)
        compose.onNodeWithTag("git-sheet").assertIsDisplayed()
        compose.onNodeWithText(gitErrorText("changed_since_review")).assertIsDisplayed()
    }

    @Test fun slowGenerationNeverOverwritesTypingAndDismissPreventsQuickCommit() {
        val fake = Fake(); fake.messageGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generating }
        compose.onNodeWithTag("git-message").performTextInput("Written by me")
        compose.runOnIdle { fake.messageGate!!.complete(Unit) }
        await { model.state.value.generated != null }
        assertEquals("Written by me", model.state.value.message)
        compose.runOnIdle { model.dismiss(); fake.messageGate = CompletableDeferred(); model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.generating }
        compose.runOnIdle { model.dismiss(); fake.messageGate!!.complete(Unit) }
        compose.waitForIdle()
        assertEquals(0, fake.commits)
    }

    @Test fun selectionChangeDiscardsObsoleteMessageAndReadOnlyCannotCommit() {
        val fake = Fake(); fake.messageGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generating }
        compose.runOnIdle { model.toggleHunk("/scratch", mine, 0); fake.messageGate!!.complete(Unit) }
        compose.waitForIdle()
        assertNull(model.state.value.generated)
        compose.runOnIdle {
            fake.snapshot.value = fake.snapshot.value.copy(access = mapOf(chat to GitAccess.ReadOnly))
            model.message("Manual message"); model.commit()
        }
        assertEquals(0, fake.commits)
        compose.onNodeWithTag("git-submit").assertDoesNotExist()
        compose.onAllNodesWithText(GitAccess.ReadOnly.reason!!).assertCountEquals(2)
    }

    @Test fun remoteShowsReasonAndNeverRequestsReview() {
        val fake = Fake(access = GitAccess.Remote)
        val model = mount(fake)
        compose.onNodeWithText(GitAccess.Remote.reason!!).assertIsDisplayed()
        compose.runOnIdle { model.open(); model.commit(); model.push() }
        assertEquals(0, fake.reviews + fake.commits + fake.pushes)
    }

    @Test fun emptySummaryWithAheadCommitsOffersPushAndNoPullBeforeRejection() {
        val fake = Fake()
        fake.snapshot.value = fake.snapshot.value.copy(summaries = emptyMap(), branches = mapOf(chat to listOf(GitBranch("/scratch", "scratch", "feature/mobile", ahead = 3, hasRemote = true))))
        mount(fake)
        compose.onNodeWithText("↑3 Push").assertIsDisplayed()
        compose.onNodeWithContentDescription("Git actions").performClick()
        compose.onNodeWithText("Pull & push").assertDoesNotExist()
        compose.onNodeWithText("Commit…").assertIsNotEnabled()
        compose.onNodeWithText("Push", substring = false).performClick()
        await { fake.pushes == 1 }
        assertFalse(fake.pulled)
        assertEquals(0, fake.commits)
    }

    @Test fun dotsAndReadOnlySettingsUseSnapshot() {
        val fake = Fake(review(files = listOf(mine.copy(ownership = GitOwnership.Unclear))))
        compose.setContent { VerdeTheme { CompositionLocalProvider(LocalGitChangesClient provides fake) {
            GitChangesDot(chat)
            GitCommitSettingsSection(GitSettings("claude", null, GitAction.CommitAndPush))
        } } }
        compose.onNodeWithContentDescription("Uncommitted changes need attention").assertExists()
        compose.onNodeWithText("Provider · Claude").assertExists()
        compose.onNodeWithText("Model · Default (fast model)").assertExists()
        compose.onNodeWithText("Change on your computer").assertExists()
    }

    @Test fun readOnlyCanReviewButHasNoMutationOrMessageControls() {
        val fake = Fake(access = GitAccess.ReadOnly)
        val model = mount(fake)
        compose.onNodeWithTag("git-primary").performClick()
        await { model.state.value.review != null }
        compose.onNodeWithText("Commit changes").assertIsDisplayed()
        compose.onNodeWithTag("git-submit").assertDoesNotExist()
        compose.onNodeWithTag("git-message").assertDoesNotExist()
        compose.runOnIdle { model.commit(); model.push(); model.toggleFile("/scratch", mine) }
        assertEquals(0, fake.messages + fake.commits + fake.pushes)
    }

    @Test fun permissionLossCannotFastCommit() {
        val fake = Fake()
        fake.messageGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.generating }
        compose.runOnIdle {
            fake.snapshot.value = fake.snapshot.value.copy(access = mapOf(chat to GitAccess.ReadOnly))
            fake.messageGate!!.complete(Unit)
        }
        await { !model.state.value.preparing }
        assertEquals(0, fake.commits)
    }

    @Test fun truncatedAndBinaryFilesOnlyAllowWholeFileSelection() {
        val file = mine.copy(binary = true, previewTruncated = true)
        val fake = Fake(review(files = listOf(file)))
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.review != null }
        compose.runOnIdle { model.toggleHunk("/scratch", file, 0) }
        assertNull(model.state.value.selections.single().files.single().hunks)
        compose.onNodeWithContentDescription("Show diff for app.kt").performClick()
        compose.onNodeWithContentDescription("Include hunk 1 of app.kt").assertDoesNotExist()
    }

    @Test fun mainConfirmationCreatesSuggestedBranch() {
        val fake = Fake(review("main"))
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.generated != null }
        compose.onNodeWithText("Create branch & continue").performClick()
        await { fake.commits == 1 && !model.state.value.busy }
        assertTrue(fake.committedNewBranch)
        assertTrue(fake.committedPush)
        assertEquals("feature/mobile-flow", fake.committedBranchName)
    }

    @Test fun sheetCanCommitOnNewBranchWithoutPush() {
        val fake = Fake()
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generated != null }
        compose.onNodeWithTag("git-new-branch").assertIsDisplayed().assertIsEnabled().performClick()
        await { fake.commits == 1 && !model.state.value.busy }
        assertTrue(fake.committedNewBranch)
        assertFalse(fake.committedPush)
        assertEquals("feature/mobile-flow", fake.committedBranchName)
    }

    @Test fun uncertainDeliveryStaysBusyUntilCoreResolvesSameCommit() {
        val fake = Fake(); fake.checking = true; fake.commitGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generated != null }
        compose.onNodeWithTag("git-submit").assertIsDisplayed().assertIsEnabled().performClick()
        await { model.state.value.checking }
        compose.onNodeWithTag("git-submit").assertTextContains("Checking commit…").assertIsNotEnabled()
        compose.runOnIdle { model.commit(); model.dismiss(); model.open() }
        assertTrue(model.state.value.busy)
        assertEquals(1, fake.commits)
        assertEquals(1, fake.reviews)
        assertNull(model.state.value.error)
        compose.runOnIdle { fake.commitGate!!.complete(Unit) }
        await { !model.state.value.busy }
        assertFalse(model.state.value.checking)
        assertNotNull(model.state.value.notice)
    }

    @Test fun movedHeadDoesNotAutomaticallyRequestAnotherReview() {
        val fake = Fake(); fake.failure = "head_moved"
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.error != null }
        assertEquals(1, fake.reviews)
        assertEquals(1, fake.commits)
        compose.onNodeWithText(gitErrorText("head_moved")).assertIsDisplayed()
    }

    @Test fun chatAndFullCanWriteButMonitorCanOnlyReview() {
        assertEquals(GitAccess.Writable, gitAccess(setOf("chat:write", "repository:read")))
        assertEquals(GitAccess.Writable, gitAccess(setOf("chat:write", "repository:read", "repository:write")))
        assertEquals(GitAccess.ReadOnly, gitAccess(setOf("repository:read")))
        assertEquals(GitAccess.Unavailable, gitAccess(setOf("chat:write")))
        assertEquals(GitAccess.Remote, gitAccess(setOf("chat:write", "repository:read"), remote = true))
    }

    @Test fun gitCommitIsQuietNoticeAndNotGroupedAsToolOutput() {
        val row = ChatRow("git-commit-123-abc", "system", author = "git", body = "Committed 1 file: 123abcd · pushed")
        assertTrue(isGitCommitRow(row))
        assertFalse(isCommandRow(row))
        compose.setContent { VerdeTheme { GitCommitNotice(row.body) } }
        compose.onNodeWithTag("git-commit-notice").assertIsDisplayed()
        compose.onNodeWithText("Committed & pushed 1 file").assertIsDisplayed()
        compose.onNodeWithText("123abcd").assertIsDisplayed()
        compose.onNodeWithText("Pushed").assertIsDisplayed()
    }

    @Test fun alternatePushRegeneratesAndKeepsBusyLabelOnTappedButton() {
        val fake = Fake(review("main", files = listOf(ownEdits)))
        fake.review = fake.review.copy(repos = fake.review.repos.map { it.copy(branch = it.branch.copy(hasRemote = true)) })
        fake.messageGate = CompletableDeferred()
        fake.commitGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.review != null }
        compose.onNodeWithTag("git-file:notes.txt").performClick()
        compose.onNodeWithTag("git-alternate").performClick()
        await { model.state.value.generating }
        compose.onNodeWithTag("git-alternate").assertTextContains("Writing message…").assertIsNotEnabled()
        compose.onNodeWithTag("git-submit").assertTextContains("Commit")
        compose.onNodeWithTag("git-confirm-main").assertDoesNotExist()
        compose.runOnIdle { fake.messageGate!!.complete(Unit) }
        await { fake.commits == 1 }
        compose.onNodeWithTag("git-alternate").assertTextContains("Committing…")
        assertTrue(fake.committedPush)
        assertFalse(fake.committedNewBranch)
        assertEquals(1, fake.committedSelections!!.single().files.size)
        compose.runOnIdle { fake.commitGate!!.complete(Unit) }
        await { !model.state.value.busy }
    }

    @Test fun alternateCommitDoesNotPushAndPushAlternativeNeedsRemote() {
        val fake = Fake()
        fake.review = fake.review.copy(repos = fake.review.repos.map { it.copy(branch = it.branch.copy(hasRemote = false)) })
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generated != null }
        compose.onNodeWithTag("git-alternate").assertDoesNotExist()
        compose.runOnIdle { model.dismiss(); model.open(GitAction.CommitAndPush) }
        await { model.state.value.generated != null }
        compose.onNodeWithTag("git-alternate").assertTextContains("Commit").performClick()
        await { fake.commits == 1 }
        assertFalse(fake.committedPush)
        assertFalse(fake.committedNewBranch)
    }

    @Test fun commitNoticeParserSupportsOldRichAndUnknownReceipts() {
        assertEquals(GitCommitNoticeData("Committed 1 file", "123abcd", false, entries = listOf(GitCommitEntry("123abcd", null, false))), parseGitCommitNotice("Committed 1 file: 123abcd"))
        assertEquals(GitCommitNoticeData("Committed 3 files", "123abcd (app), abc1234 (lib)", true, "Improve fixtures", "feature/fixtures", listOf(GitCommitEntry("123abcd (app)", "app", true), GitCommitEntry("abc1234 (lib)", "lib", true))),
            parseGitCommitNotice("Committed 3 files: 123abcd (app) · pushed, abc1234 (lib) · pushed\nImprove fixtures\nbranch feature/fixtures"))
        assertEquals("feature/fixtures", parseGitCommitNotice("Committed 1 file: 123abcd\n\nbranch feature/fixtures").branch)
        assertNull(parseGitCommitNotice("Committed 1 file: 123abcd\n\nbranch feature/fixtures").subject)
        assertEquals(GitCommitNoticeData("Unknown receipt", null, false), parseGitCommitNotice("Unknown receipt"))
        compose.setContent { VerdeTheme { GitCommitNotice("Committed 3 files: 123abcd · pushed\nImprove fixtures\nbranch feature/fixtures") } }
        compose.onNodeWithText("Improve fixtures").assertIsDisplayed()
        compose.onNodeWithText("branch feature/fixtures").assertIsDisplayed()
    }

    @Test fun positionalReceiptLinksAndUpdatedBodyReplacePushControl() {
        val chatState = GitChangesState(snapshot = GitSnapshot(connected = true, access = mapOf(chat to GitAccess.Writable),
            branches = mapOf(chat to listOf(GitBranch("/scratch", "scratch", ahead = 2, hasRemote = true)))))
        val original = "Committed 1 file: 123abcd"
        val updated = "Committed 2 files: 123abcd (app) · pushed, abc1234 (lib) · pushed\n\nbranch feature/test\nremote https://github.com/example/repo/commit/123abcd\nremote https://gitlab.com/example/repo/commit/123abcd"
        val parsed = parseGitCommitNotice(updated)
        assertNull(parsed.subject)
        assertEquals("feature/test", parsed.branch)
        assertEquals(2, parsed.remotes.size)
        assertTrue(showGitCardPush(parseGitCommitNotice(original), chatState, chat))
        assertFalse(showGitCardPush(parsed, chatState, chat))
        assertFalse(showGitCardPush(parseGitCommitNotice(original), chatState.copy(snapshot = chatState.snapshot.copy(access = mapOf(chat to GitAccess.ReadOnly))), chat))
        assertNull(gitCommitLinkHost("javascript:alert(1)"))
        assertNull(gitCommitLinkHost("https://user:secret@example.com/commit/123abcd"))
        assertNull(gitCommitLinkHost("http://example.com/commit/123abcd"))
        assertEquals("branch named subject", parseGitCommitNotice("$original\nbranch named subject\n\nremote https://github.com/a/b/commit/123abcd").subject)
        val fake = Fake(); fake.snapshot.value = chatState.snapshot
        val model = GitChangesModel(chat, fake); models.put("git", model)
        val body = androidx.compose.runtime.mutableStateOf(original)
        compose.setContent { VerdeTheme { GitCommitNotice(body.value, model) } }
        compose.onNodeWithTag("git-card-push").assertIsDisplayed()
        compose.runOnIdle { body.value = updated }
        compose.onNodeWithTag("git-card-push").assertDoesNotExist()
        compose.onNodeWithText("Committed & pushed 2 files").assertIsDisplayed()
        compose.onNodeWithText("View on github.com").assertIsDisplayed()
        compose.onNodeWithText("View on gitlab.com").assertIsDisplayed()
    }

    @Test fun commitMarkersPreserveRepoPositionsAndNeverLinkUnpushedEntries() {
        val notice = parseGitCommitNotice("Committed 4 files: 123abcd (local), abc1234 (old), bbb1234 (pushed) · pushed, ccc1234 (unknown)\nSubject\nbranch feature/test\nlocal\nremote https://github.com/a/b/commit/abc1234\nremote https://gitlab.com/a/b/commit/bbb1234")
        assertTrue(notice.entries[0].local)
        assertNull(notice.entries[1].url) // Old daemon rows emitted links before push.
        assertEquals(listOf("https://gitlab.com/a/b/commit/bbb1234"), notice.remotes)
        assertFalse(notice.entries[3].local) // Missing trailing marker means unknown/remote.
        assertFalse(notice.pushed)
        val state = GitChangesState(snapshot = GitSnapshot(access=mapOf(chat to GitAccess.Writable), branches=mapOf(chat to
            listOf("local", "old", "pushed", "unknown").map { GitBranch("/$it", it, ahead=1, hasRemote=true) })))
        assertEquals(setOf("/old", "/unknown"), gitCardPushRoots(notice, state, chat))
        val bare = parseGitCommitNotice("Committed 2 files: 123abcd (a), abc1234 (b)\n\n\nremote\nlocal")
        assertFalse(bare.entries[0].local)
        assertTrue(bare.entries[1].local)
        assertTrue(bare.remotes.isEmpty())
    }

    @Test fun mixedCardPushTargetsOnlyUnpushedRemoteRepo() {
        val fake = Fake()
        fake.snapshot.value = GitSnapshot(connected=true, access=mapOf(chat to GitAccess.Writable),
            branches=mapOf(chat to listOf("local", "remote").map { GitBranch("/$it", it, ahead=1, hasRemote=true) }))
        val model = GitChangesModel(chat, fake); models.put("git", model)
        compose.setContent { VerdeTheme {
            GitCommitNotice("Committed 2 files: 123abcd (local), abc1234 (remote)\n\n\nlocal\nremote", model)
        } }
        compose.onNodeWithTag("git-card-push").performClick()
        await { fake.pushes == 1 && !model.state.value.busy }
        assertEquals(listOf("/remote"), fake.pushedRoots)
        compose.onNodeWithText("local: Local only · no remote").assertIsDisplayed()
    }

    @Test fun localOnlyCardHidesPushAndOldUnpushedLinks() {
        val fake = Fake()
        fake.snapshot.value = GitSnapshot(connected=true, access=mapOf(chat to GitAccess.Writable),
            branches=mapOf(chat to listOf(GitBranch("/scratch", "scratch", ahead=1, hasRemote=true))))
        val model = GitChangesModel(chat, fake); models.put("git", model)
        val body = androidx.compose.runtime.mutableStateOf("Committed 1 file: 0aae44a\nSubject\nbranch main\nremote https://github.com/a/b/commit/0aae44a")
        compose.setContent { VerdeTheme { GitCommitNotice(body.value, model) } }
        compose.onNodeWithText("View on github.com").assertDoesNotExist()
        compose.onNodeWithText("Not pushed").assertIsDisplayed()
        compose.onNodeWithTag("git-card-push").assertIsDisplayed()
        compose.runOnIdle { body.value = "Committed 1 file: 0aae44a\nSubject\nbranch main\nlocal" }
        compose.onNodeWithText("Local only · no remote").assertIsDisplayed()
        compose.onNodeWithTag("git-card-push").assertDoesNotExist()
        compose.onNodeWithText("Not pushed").assertDoesNotExist()
        compose.runOnIdle {
            body.value = "Committed 1 file: 0aae44a\nSubject\nbranch main\nremote"
            fake.snapshot.value = fake.snapshot.value.copy(branches=emptyMap())
        }
        compose.onNodeWithText("Not pushed").assertDoesNotExist()
        compose.onNodeWithText("Local only · no remote").assertDoesNotExist()
        compose.onNodeWithTag("git-card-push").assertDoesNotExist()
    }

    @Test fun resultCardShowsProgressThenSuccessAndDismisses() {
        val fake = Fake(); fake.commitGate = CompletableDeferred()
        val model = mount(fake)
        compose.runOnIdle { model.open() }
        await { model.state.value.generated != null }
        compose.onNodeWithTag("git-submit").performClick()
        await { fake.commits == 1 }
        assertEquals(GitResultPhase.Running, model.state.value.notice?.phase)
        compose.onNodeWithTag("git-result").assertIsDisplayed()
        compose.runOnIdle { fake.commitGate!!.complete(Unit) }
        await { model.state.value.notice?.phase == GitResultPhase.Success }
        compose.onNodeWithText("Committed 1 file").assertIsDisplayed()
        assertTrue(model.state.value.notice!!.detail.contains("123abcd"))
        compose.onNodeWithContentDescription("Dismiss Git result").performClick()
        assertNull(model.state.value.notice)
    }

    @Test fun headerCommitUsesOnlyMineAndReportsExcludedFiles() {
        val fake = Fake(review("main", listOf(mine, ownEdits, mine.copy(path = "shared.kt", ownership = GitOwnership.Shared), mine.copy(path = "unclear.kt", ownership = GitOwnership.Unclear))))
        val model = mount(fake)
        compose.onNodeWithTag("git-primary").assertTextContains("1").performClick()
        await { fake.commits == 1 && !model.state.value.busy }
        assertFalse(fake.committedPush)
        assertEquals(listOf(GitSelection("/scratch", listOf(GitFileSelection("app.kt")))), fake.committedSelections)
        assertTrue(model.state.value.notice!!.detail.startsWith("2 files left out (shared/unclear) — use Commit… to review them"))
        compose.onNodeWithTag("git-sheet").assertDoesNotExist()
        compose.onNodeWithTag("git-confirm-main").assertDoesNotExist()
    }

    @Test fun quickPushIgnoresDefaultRepoWithoutMineAndUsesSingularExclusion() {
        val fake = Fake(review().copy(repos = review().repos + GitRepo(GitBranch("/other", "other", "main", isDefault = true), files = listOf(ownEdits, mine.copy(ownership = GitOwnership.Shared)))))
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { fake.commits == 1 && !model.state.value.busy }
        assertTrue(fake.committedPush)
        assertEquals(listOf(GitSelection("/scratch", listOf(GitFileSelection("app.kt")))), fake.committedSelections)
        assertTrue(model.state.value.notice!!.detail.startsWith("1 file left out (shared/unclear)"))
        compose.onNodeWithTag("git-confirm-main").assertDoesNotExist()
    }

    @Test fun emptyQuickReviewShowsNoticeWithoutGeneratingOrCommitting() {
        val fake = Fake(review(files = emptyList()))
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.Commit, true) }
        await { !model.state.value.loading }
        compose.onNodeWithText("No uncommitted changes").assertIsDisplayed()
        compose.onNodeWithTag("git-sheet").assertDoesNotExist()
        assertEquals(0, fake.commits + fake.messages)
    }

    @Test fun namedErrorsHavePlainActionableCopy() {
        mapOf("changed_since_review" to "Files changed", "head_moved" to "branch changed", "review_expired" to "expired",
            "missing_git_identity" to "name and email", "turns_running" to "still working", "in_progress" to "Checking commit",
            "branch_create_failed" to "Nothing was committed").forEach { (code, text) -> assertTrue(gitErrorText(code).contains(text)) }
        assertFalse(gitErrorText("opaque-secret-from-host").contains("opaque-secret"))
    }
}
