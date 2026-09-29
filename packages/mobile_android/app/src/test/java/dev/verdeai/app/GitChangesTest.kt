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
        "review-1", chat, running, repos = listOf(GitRepo(GitBranch("/scratch", "scratch", branch, hasRemote = true), "fixture-head", files)))
    private inner class Fake(var review: GitReview = review(), access: GitAccess = GitAccess.Writable) : GitChangesClient {
        override val snapshot = MutableStateFlow(GitSnapshot(
            summaries = mapOf(chat to GitSummary(review.repos.sumOf { it.files.size }, 2, 1, review.repos.flatMap { it.files }.count { it.ownership != GitOwnership.Mine })),
            branches = mapOf(chat to review.repos.map { it.branch }), access = mapOf(chat to access), connected = true))
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
        override suspend fun push(chat: GitChat, root: String, pull: Boolean, requestId: String, onChecking: (Boolean) -> Unit): GitPush { pushes++; pulled = pull; return GitPush.Pushed }
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
        compose.onNodeWithText("Committed 1 file · 123abcd · pushed").assertIsDisplayed()
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

    @Test fun attentionAndRunningTurnsAlwaysOpenReviewInsteadOfQuickCommit() {
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
        compose.onNodeWithText("Frozen snapshot", substring = true).assertIsDisplayed()
        assertEquals(0, fake.commits)
    }

    @Test fun rejectedPushKeepsCommitAndOffersExplicitPullPush() {
        val fake = Fake(); fake.outcome = GitPush.Rejected
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.notice != null }
        compose.onNodeWithText("Committed 1 file · 123abcd · push rejected").assertIsDisplayed()
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

    @Test fun detachedHeadAndPermissionLossCannotFastCommit() {
        val fake = Fake(review(branch = null))
        val model = mount(fake)
        compose.runOnIdle { model.open(GitAction.CommitAndPush, true) }
        await { model.state.value.review != null }
        compose.onNodeWithTag("git-sheet").assertIsDisplayed()
        assertEquals(0, fake.commits)
        compose.runOnIdle {
            model.dismiss(); fake.review = review(); fake.messageGate = CompletableDeferred()
            model.open(GitAction.CommitAndPush, true)
        }
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
        compose.onNodeWithTag("git-commit-notice").assertTextContains(row.body).assertIsDisplayed()
    }

    @Test fun namedErrorsHavePlainActionableCopy() {
        mapOf("changed_since_review" to "Files changed", "head_moved" to "branch changed", "review_expired" to "expired",
            "missing_git_identity" to "name and email", "turns_running" to "still working", "in_progress" to "Checking commit",
            "branch_create_failed" to "Nothing was committed").forEach { (code, text) -> assertTrue(gitErrorText(code).contains(text)) }
        assertFalse(gitErrorText("opaque-secret-from-host").contains("opaque-secret"))
    }
}
