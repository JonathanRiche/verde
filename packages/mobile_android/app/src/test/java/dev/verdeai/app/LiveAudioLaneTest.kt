package dev.verdeai.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Live's audio lane: setup and teardown stay in order and the call route is held across overlapping calls. */
class LiveAudioLaneTest {
    private val executor = Executors.newSingleThreadExecutor()
    private val dispatcher = executor.asCoroutineDispatcher()
    private val events: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val lane = LiveAudioLane(dispatcher, acquire = { events += "acquire" }, release = { events += "release" })

    @After fun close() { dispatcher.close() }

    /** Blocks the lane until the returned latch opens, so work queues up behind it. */
    private fun blockLane(): CountDownLatch {
        val gate = CountDownLatch(1)
        executor.execute { gate.await(5, TimeUnit.SECONDS) }
        return gate
    }

    private fun drain() = executor.submit {}.get(5, TimeUnit.SECONDS)

    @Test fun oneCallAcquiresThenReleases() = runBlocking {
        lane.hold(this).join()
        lane.drop()
        assertEquals(listOf("acquire", "release"), events)
    }

    /** End then Start at once: the ending call's release lands after the new call's hold, so the route stays up. */
    @Test fun endThenStartKeepsTheRoute() = runBlocking {
        val gate = blockLane()
        val first = Job()
        lane.hold(CoroutineScope(first))
        val second = Job()
        lane.hold(CoroutineScope(second))
        first.cancel()
        val ending = launch { lane.drop() }
        gate.countDown()
        ending.join()
        drain()
        assertEquals(listOf("acquire"), events)
        lane.drop()
        assertEquals(listOf("acquire", "release"), events)
    }

    /** A call cancelled before its hold ran still takes it, so its drop is balanced and the route isn't left on. */
    @Test fun cancelledBeforeTheHoldRanStaysBalanced() = runBlocking {
        val gate = blockLane()
        val call = Job()
        lane.hold(CoroutineScope(call))
        call.cancel()
        gate.countDown()
        lane.drop()
        assertEquals(listOf("acquire", "release"), events)
        // A stray extra drop never releases twice.
        lane.drop()
        assertEquals(listOf("acquire", "release"), events)
    }

    /** Teardown queued from a cancelled coroutine still runs, after the setup queued before it. */
    @Test fun teardownRunsInOrderEvenWhenCancelled() = runBlocking {
        val gate = blockLane()
        // Undispatched like the app's Main.immediate: it queues its work before being cancelled.
        val call = launch(start = CoroutineStart.UNDISPATCHED) {
            lane.launch(this@runBlocking) { events += "mic start" }
            try { lane.run { events += "speaker start" } } finally { lane.runAlways { events += "mic stop"; events += "speaker stop" } }
        }
        call.cancel()
        gate.countDown()
        withTimeout(5_000) { call.join() }
        drain()
        assertEquals(listOf("mic start", "mic stop", "speaker stop"), events)
    }

    /** Cancellable setup waiting its turn never runs once its call has ended. */
    @Test fun cancelledSetupIsSkipped() = runBlocking {
        val gate = blockLane()
        val call = launch(start = CoroutineStart.UNDISPATCHED) { lane.run { events += "speaker start" } }
        call.cancelAndJoin()
        gate.countDown()
        drain()
        assertEquals(emptyList<String>(), events)
    }
}
