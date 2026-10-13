package dev.verdeai.app

import dev.verdeai.core.*
import org.junit.Assert.*
import org.junit.Test

class AttachmentImagesTest {
    private fun image(index: Long? = 0, mime: String = "image/png") = ChatAttachment(local_id = "/tmp/a.png", name = "/tmp/a.png", mime = mime,
        byte_size = "10", status = "committed", index = index)
    private fun row(messageId: String? = "m1", attachments: List<ChatAttachment> = listOf(image())) =
        ChatRow(id = messageId ?: "turn:1:user", role = "user", body = "look", attachments = attachments, message_id = messageId)

    @Test fun keysMatchTheCoreAndCacheNamesAreStableHashes() {
        assertEquals("ws|t1|m1|2", attachmentKey("ws", "t1", "m1", 2))
        val name = attachmentCacheName("host", "ws|t1|m1|2")
        assertEquals(name, attachmentCacheName("host", "ws|t1|m1|2"))
        assertTrue(name.matches(Regex("[0-9a-f]{64}\\.img")))
        assertNotEquals(name, attachmentCacheName("other-host", "ws|t1|m1|2"))
        assertNotEquals(name, attachmentCacheName("host", "ws|t1|m1|3"))
    }

    @Test fun onlyStoredImagesWithAnIndexAreFetchable() {
        val target = attachmentTarget("ws", "t1", row(), image(index = 1))!!
        assertEquals(AttachmentTarget("ws", "t1", "m1", 1), target)
        assertEquals("ws|t1|m1|1", target.key)
        // Optimistic rows (no stored message id), legacy attachments without an index, and non-images.
        assertNull(attachmentTarget("ws", "t1", row(messageId = null), image()))
        assertNull(attachmentTarget("ws", "t1", row(), image(index = null)))
        assertNull(attachmentTarget("ws", "t1", row(), image(mime = "application/pdf")))
    }

    @Test fun statusMapsToTheUiAndDownsamplingStaysWithinTheTarget() {
        assertEquals(ImageStatus.Loading, imageStatus(null))
        assertEquals(ImageStatus.Loading, imageStatus(AttachmentItem(key = "k")))
        assertEquals(ImageStatus.Ready, imageStatus(AttachmentItem(key = "k", status = "ready")))
        assertEquals(ImageStatus.Unavailable, imageStatus(AttachmentItem(key = "k", status = "unavailable")))
        assertEquals(ImageStatus.Failed, imageStatus(AttachmentItem(key = "k", status = "failed", error_code = "too_large")))
        assertEquals(1, sampleSize(400, 300, 480))
        assertEquals(1, sampleSize(900, 600, 480))
        assertEquals(2, sampleSize(1000, 600, 480))
        assertEquals(8, sampleSize(4032, 3024, 480))
        assertEquals(1, sampleSize(3000, 4032, 2048))
        assertEquals(2, sampleSize(8000, 6000, 2048))
    }
}
