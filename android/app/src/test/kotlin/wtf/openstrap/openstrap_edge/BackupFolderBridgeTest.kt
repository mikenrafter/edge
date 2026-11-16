package wtf.openstrap.openstrap_edge

import android.provider.DocumentsContract
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BackupFolderBridgeTest {
    @Test
    fun publishingRequiresWriteRenameAndDeleteSupport() {
        val flags = DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
            DocumentsContract.Document.FLAG_SUPPORTS_RENAME or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        assertTrue(canPublishBackup(flags))
        for (missing in listOf(DocumentsContract.Document.FLAG_SUPPORTS_WRITE,
            DocumentsContract.Document.FLAG_SUPPORTS_RENAME, DocumentsContract.Document.FLAG_SUPPORTS_DELETE)) {
            assertFalse(canPublishBackup(flags and missing.inv()))
        }
    }

    @Test
    fun backupNamesStayWithinTheChosenDirectory() {
        requireBackupFileName("openstrap-20261007-120000.db.gz.partial")
        requireBackupFileName("openstrap-20261007-120000-2.db.gz")
        for (name in listOf("", ".", "..", "../backup", "folder/backup", "folder\\backup", "a\u0000b")) {
            var rejected = false
            try { requireBackupFileName(name) } catch (_: IllegalArgumentException) { rejected = true }
            assertTrue("must reject $name", rejected)
        }
    }
    // WHY: encrypted read-back must not give a document provider an arbitrary
    // private-file write path. Proves CLAIM(export-scoped-file-access).
    @Test
    fun readBackIsConfinedToPrivateCacheIncludingCanonicalPaths() {
        val root = Files.createTempDirectory("official-export-scope").toFile()
        try {
            val cache = File(root, "cache").apply { mkdirs() }
            val nested = File(cache, "official-export/session/readback.osbk")
            assertTrue(requirePrivateBackupDestination(cache, nested) == nested.canonicalFile)
            val outside = File(root, "outside").apply { mkdirs() }
            val link = File(cache, "escape")
            Files.createSymbolicLink(link.toPath(), outside.toPath())
            for (path in listOf(File(root, "cache-sibling/secret"),
                File(cache, "../outside/secret"), File(link, "secret"), cache)) {
                var rejected = false
                try { requirePrivateBackupDestination(cache, path) }
                catch (_: IllegalArgumentException) { rejected = true }
                assertTrue("must reject $path", rejected)
            }
        } finally { root.deleteRecursively() }
    }

}
