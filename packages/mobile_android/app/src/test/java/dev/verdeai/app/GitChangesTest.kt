package dev.verdeai.app

import org.junit.Assert.*
import org.junit.Test

/** Git commit receipt parsing and link safety. Synthetic receipts only. */
class GitChangesTest {
    @Test fun commitNoticeParserSupportsOldRichAndUnknownReceipts() {
        assertEquals(GitCommitNoticeData("Committed 1 file", "123abcd", false), parseGitCommitNotice("Committed 1 file: 123abcd"))
        assertEquals(GitCommitNoticeData("Committed 3 files", "123abcd (app), abc1234 (lib)", true, "Improve fixtures", "feature/fixtures"),
            parseGitCommitNotice("Committed 3 files: 123abcd (app), abc1234 (lib) · pushed\nImprove fixtures\nbranch feature/fixtures"))
        assertEquals("feature/fixtures", parseGitCommitNotice("Committed 1 file: 123abcd\n\nbranch feature/fixtures").branch)
        assertNull(parseGitCommitNotice("Committed 1 file: 123abcd\n\nbranch feature/fixtures").subject)
        assertEquals(GitCommitNoticeData("Unknown receipt", null, false), parseGitCommitNotice("Unknown receipt"))
        val original = "Committed 1 file: 123abcd"
        val updated = "$original · pushed\n\nbranch feature/test\nremote https://github.com/example/repo/commit/123abcd\nremote https://gitlab.com/example/repo/commit/123abcd"
        val parsed = parseGitCommitNotice(updated)
        assertNull(parsed.subject)
        assertEquals("feature/test", parsed.branch)
        assertEquals(2, parsed.remotes.size)
        assertEquals("branch named subject", parseGitCommitNotice("$original\nbranch named subject\n\nremote https://github.com/a/b/commit/123abcd").subject)
    }

    @Test fun commitLinksOnlyAcceptPlainHttpsCommitUrls() {
        assertEquals("github.com", gitCommitLinkHost("https://github.com/example/repo/commit/123abcd"))
        assertNull(gitCommitLinkHost("javascript:alert(1)"))
        assertNull(gitCommitLinkHost("https://user:secret@example.com/commit/123abcd"))
        assertNull(gitCommitLinkHost("http://example.com/commit/123abcd"))
    }
}
