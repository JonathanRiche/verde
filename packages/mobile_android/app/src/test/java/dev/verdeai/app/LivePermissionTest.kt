package dev.verdeai.app

import org.junit.Assert.*
import org.junit.Test

class LivePermissionTest {
    @Test fun pendingPermissionAlreadyPresentsConnecting() {
        assertEquals(LivePhase.Connecting, permissionLiveUi(LiveUi(), true).phase)
        assertEquals(LivePhase.Connecting, permissionLiveUi(LiveUi(phase = LivePhase.Failed, error = "old"), true).phase)
        val active = LiveUi(phase = LivePhase.Live)
        assertSame(active, permissionLiveUi(active, true))
        val idle = LiveUi()
        assertSame(idle, permissionLiveUi(idle, false))
    }

    @Test fun permissionCompletesOnceAndCancelledRequestsCannotStartLater() {
        val pending = MicPermissionAction()
        var starts = 0; var dismissals = 0
        pending.begin({ starts++ }, { dismissals++ })
        pending.finish(true); pending.finish(true)
        assertEquals(1, starts); assertEquals(0, dismissals)
        pending.begin({ starts++ }, { dismissals++ })
        pending.finish(false); pending.finish(true)
        assertEquals(1, starts); assertEquals(1, dismissals)
        pending.begin({ starts++ }, { dismissals++ })
        pending.begin({ starts++ }, { dismissals++ })
        assertEquals(2, dismissals)
        pending.finish(true)
        assertEquals(2, starts)
    }
}
