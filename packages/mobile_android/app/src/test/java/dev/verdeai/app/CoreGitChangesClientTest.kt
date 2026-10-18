package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CoreGitChangesClientTest {
    private val chat = GitChat("scratch", "chat")
    private class Connection : GitCoreConnection {
        override val views = MutableStateFlow<Map<String, JsonElement>>(emptyMap())
        override val operations = MutableStateFlow<OperationsQuery?>(null)
        val sent = mutableListOf<Event>()
        var handle: (Event) -> Unit = {}
        override suspend fun query(selector: String) = views.value[selector] ?: error("missing_fixture")
        override suspend fun send(event: (Long, Long) -> Event) { val value=event(100,200); sent += value; handle(value) }
        fun settle(id: String, state: String, code: String? = null) {
            operations.value = CoreJson.decodeFromJsonElement(buildJsonObject {
                put("api_version", 1); put("revision", sent.size.toString()); put("error", JsonNull)
                putJsonObject("data") { putJsonArray("items") { add(buildJsonObject {
                    put("intent_id", id); put("state", state)
                    put("error", if (code == null) JsonNull else buildJsonObject { put("code", code); put("message", "fixture") })
                }) } }
            })
        }
        fun review(extra: String = "") {
            views.value = views.value + ("git_review" to CoreJson.parseToJsonElement("""{
                "api_version":1,"revision":"1","error":null,"data":{
                "state":"loaded","can_commit":true,
                "review":{"review_id":"r1","workspace_id":"scratch","local_thread_id":"chat","turn_running":false,"default_action":"commit_and_push","repos":[{
                "root":"/scratch","name":"scratch","branch":"main","head":"head","default_branch":"main","is_default_branch":true,"ahead":2,"has_remote":true,
                "files":[{"path":"a.kt","status":"modified","ownership":"mine","additions":1,"deletions":0,"binary":false,"hunk_selectable":false,"preview_truncated":true}]}]}
                $extra}}"""))
        }
    }
    private fun fixture(test: suspend CoroutineScope.(Connection, CoreGitChangesClient) -> Unit) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val connection = Connection()
        val adapter = CoreGitChangesClient(connection, scope)
        try { withTimeout(5000) { scope.test(connection, adapter) } }
        finally { adapter.close(); scope.cancel() }
    }

    @Test fun reviewAndBranchOptionsUseGeneratedCoreEvents() = fixture { core, adapter ->
        core.handle = { event -> when(event) {
            is EventGitReviewOpen -> { core.review(); core.settle(event.intent_id, "succeeded") }
            is EventGitMessageGenerate -> {
                core.review(""", "message_state":"ready","message":{"message":"Improve fixture","branch":"feature/fixture","provider":"codex","model":"fast"}""")
                core.settle(event.intent_id, "succeeded")
            }
            is EventGitCommit -> {
                core.review(""", "mutation_state":"succeeded","result":{"workspace_id":"scratch","local_thread_id":"chat","files":1,"repos":[{"root":"/scratch","commit":"123abcd456","short_commit":"123abcd","subject":"Improve fixture","files":1,"branch":"feature/fixture","branch_created":true,"push":"pushed"}]}""")
                core.settle(event.intent_id, "succeeded")
            }
            else -> error("unexpected_event")
        } }
        val review = adapter.review(chat)
        assertTrue(review.repos.single().branch.defaultOrMain)
        assertTrue(review.repos.single().files.single().previewTruncated)
        val selection = listOf(GitSelection("/scratch", listOf(GitFileSelection("a.kt"))))
        val message = adapter.message(review.id, selection)
        val result = adapter.commit(review.id, message.message, selection, true, true, message.branch) {}
        val request = core.sent.filterIsInstance<EventGitCommit>().single()
        assertEquals("r1", request.review_id)
        assertEquals("feature/fixture", request.branch_name)
        assertTrue(request.new_branch)
        assertTrue(request.push)
        assertNull(request.selections.single().files.single().hunks)
        assertTrue(result.repos.single().branchCreated)
        assertEquals(GitPush.Pushed, result.repos.single().push)
    }

    @Test fun uncertainReceiptWaitsForSameIntentAndExplicitRetryDoesNotResubmitCommit() = fixture { core, adapter ->
        var original = ""
        core.handle = { event -> when(event) {
            is EventGitCommit -> { original=event.intent_id; core.review(""", "mutation_state":"uncertain","can_retry":true"""); core.settle(original, "uncertain", "uncertain") }
            is EventGitRetry -> core.settle(event.intent_id, "succeeded")
            else -> error("unexpected_event")
        } }
        var canRetry = false
        val job = async { adapter.commit("r1", "fixture", listOf(GitSelection("/scratch", listOf(GitFileSelection("a.kt")))), false, false, null) { canRetry=it } }
        yield()
        assertTrue(canRetry)
        assertFalse(job.isCompleted)
        adapter.retry()
        assertEquals(1, core.sent.filterIsInstance<EventGitCommit>().size)
        assertEquals(1, core.sent.filterIsInstance<EventGitRetry>().size)
        core.review(""", "mutation_state":"succeeded","result":{"workspace_id":"scratch","local_thread_id":"chat","files":1,"repos":[{"root":"/scratch","commit":"123abcd456","short_commit":"123abcd","subject":"fixture","files":1,"push":"not_requested"}]}""")
        core.settle(original, "succeeded")
        assertEquals("123abcd", job.await().repos.single().shortCommit)
    }

    @Test fun failedReceiptMapsOnlyCodeAndDoesNotReplayMutation() = fixture { core, adapter ->
        core.handle = { event -> if (event is EventGitCommit) core.settle(event.intent_id, "failed", "branch_create_failed") }
        try {
            adapter.commit("r1", "fixture", emptyList(), false, true, null) {}
            fail("expected failure")
        } catch (e: GitFailure) { assertEquals("branch_create_failed", e.code) }
        assertEquals(1, core.sent.size)
    }

    @Test fun closedHostBoundaryCannotSendIntoAnotherHost() = fixture { core, adapter ->
        adapter.close()
        try { adapter.review(chat); fail("expected failure") } catch (e: GitFailure) { assertEquals("offline", e.code) }
        assertTrue(core.sent.isEmpty())
    }
}
