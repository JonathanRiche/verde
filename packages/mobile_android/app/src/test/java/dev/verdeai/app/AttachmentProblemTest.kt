package dev.verdeai.app

import org.junit.Assert.assertEquals
import org.junit.Test

/** What a transcript image without a preview says, from the core's settled error code (same strings as iOS). */
class AttachmentProblemTest {
    @Test fun aHostThatRefusesTheReadAsksForAnUpdate() {
        listOf("forbidden", "insufficient_scope", "method_not_found", "unknown_method", "not_allowed", "unauthorized").forEach { code ->
            listOf(ImageStatus.Failed, ImageStatus.Unavailable).forEach { status ->
                assertEquals(code, ImageProblem.HostTooOld, imageProblem(status, code))
            }
        }
        assertEquals("Update verde on this host to see images", imageProblemText(ImageProblem.HostTooOld))
    }

    @Test fun anImageThatIsGoneSaysSo() {
        assertEquals(ImageProblem.Gone, imageProblem(ImageStatus.Failed, "not_found"))
        assertEquals(ImageProblem.Gone, imageProblem(ImageStatus.Failed, "unavailable"))
        assertEquals(ImageProblem.Gone, imageProblem(ImageStatus.Unavailable, null))
        assertEquals("Preview unavailable", imageProblemText(ImageProblem.Gone))
    }

    @Test fun aHiccupOffersRetry() {
        // A timeout or a send that never reached the host has no code; network codes are transient too.
        assertEquals(ImageProblem.Transient, imageProblem(ImageStatus.Failed, null))
        assertEquals(ImageProblem.Transient, imageProblem(ImageStatus.Failed, "timeout"))
        assertEquals(ImageProblem.Transient, imageProblem(ImageStatus.Failed, "disconnected"))
        assertEquals("Couldn't load image", imageProblemText(ImageProblem.Transient))
    }
}
