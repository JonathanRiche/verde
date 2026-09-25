package dev.verdeai.app

import android.content.Intent
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35])
class PairIntentTest {
    @Test fun consumesViewDataOnceAndIgnoresOtherActions() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("verde://pair#fixture"))
        assertNotNull(takePairLink(intent))
        assertNull(intent.data)
        assertNull(takePairLink(intent))
        val other = Intent(Intent.ACTION_SEND, Uri.parse("verde://pair#fixture"))
        assertNull(takePairLink(other))
        assertNull(other.data)
    }
    @Test fun manifestMatchesOnlyThePairRoutes() {
        val app = RuntimeEnvironment.getApplication()
        fun matches(route: String): Boolean {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(route)).addCategory(Intent.CATEGORY_BROWSABLE)
                .setPackage(app.packageName)
            return app.packageManager.queryIntentActivities(intent, 0).any { it.activityInfo.name == MainActivity::class.java.name }
        }
        assertTrue(matches("verde://pair"))
        assertTrue(matches("https://verdeai.dev/pair"))
        assertFalse(matches("http://verdeai.dev/pair"))
        assertFalse(matches("https://other.invalid/pair"))
        assertFalse(matches("https://verdeai.dev/other"))
    }
}
