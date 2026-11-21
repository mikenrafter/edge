package wtf.openstrap.openstrap_edge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import android.os.StatFs
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/** SAF operations for a chosen backup folder. No broad storage permission.
 * Registered on the cached engine so writes do not depend on an Activity.
 * The picker alone borrows the visible Activity, like CompanionBridge.
 */
object BackupFolderBridge {
    private const val REQUEST_PICK_FOLDER = 0x5A41
    private const val PROBE = 64L * 1024
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val cipherWrites = mutableMapOf<String, Pair<String, OutputStream>>()
    private val cipherReads = mutableMapOf<String, Pair<String, InputStream>>()
    private var pendingPick: MethodChannel.Result? = null
    // Progress and cancellation of the one running OSBK pass, read and set from the main thread
    // while the worker is busy with it.
    private val cipherBytes = AtomicLong(0)
    @Volatile private var cipherCancelled = false

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "openstrap/backup_folder")
            .setMethodCallHandler { call, result ->
                if (call.method == "pick") {
                    pick(result)
                } else if (call.method == "cipherProgress") {
                    result.success(cipherBytes.get())
                } else if (call.method == "cipherCancel") {
                    cipherCancelled = true
                    result.success(null)
                } else if (call.method in setOf("list", "write", "rename", "delete", "release", "freeSpace", "openCiphertext", "appendCiphertext", "closeCiphertext", "readCiphertext", "closeCiphertextRead", "shareCiphertext", "encryptCiphertext", "verifyCiphertext", "probeCiphertext")) {
                    run(result) { dispatch(app, call) }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun run(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (e: Exception) {
                val code = if (e is SecurityException) "folder_access_lost" else "folder_io"
                val message = if (e is SecurityException) {
                    "Backup folder is unavailable. Choose it again or use the default folder."
                } else {
                    e.message ?: "Could not access the backup folder."
                }
                main.post { result.error(code, message, null) }
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        val activity = CompanionBridge.currentActivity
        if (activity == null || activity.isFinishing) {
            result.error("no_activity", "Open the app to choose a backup folder.", null)
            return
        }
        if (pendingPick != null) {
            result.error("picker_busy", "A folder picker is already open.", null)
            return
        }
        pendingPick = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_PICK_FOLDER)
        } catch (e: Exception) {
            pendingPick = null
            result.error("picker_failed", e.message, null)
        }
    }

    fun cancelPicker() {
        val result = pendingPick ?: return
        pendingPick = null
        result.success(null)
    }

    fun handleActivityResult(context: Context, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_FOLDER) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        run(result) {
            if (flags != (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
                throw SecurityException("Read and write access is required.")
            }
            val resolver = context.contentResolver
            val alreadyGranted = resolver.persistedUriPermissions.any { it.uri == uri }
            resolver.takePersistableUriPermission(uri, flags)
            try {
                val root = root(context, uri.toString())
                val info = document(context, root)
                if ((info.flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) == 0) {
                    throw IOException("This folder does not allow backups to be created. Choose another folder.")
                }
                mapOf("uri" to uri.toString(), "name" to info.name, "newGrant" to !alreadyGranted)
            } catch (e: Exception) {
                if (!alreadyGranted) {
                    try { resolver.releasePersistableUriPermission(uri, flags) } catch (_: Exception) {}
                }
                throw e
            }
        }
        return true
    }

    private data class Document(val uri: Uri, val name: String, val flags: Int, val directory: Boolean) {
        fun json() = mapOf("uri" to uri.toString(), "name" to name)
    }

    private val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
    )

    private fun root(context: Context, tree: String): Uri {
        val uri = Uri.parse(tree)
        if (uri.scheme != "content" || !DocumentsContract.isTreeUri(uri) ||
            context.contentResolver.persistedUriPermissions.none {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }) {
            throw SecurityException("The saved folder grant is unavailable.")
        }
        return DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
    }

    private fun document(context: Context, uri: Uri): Document {
        val cursor = context.contentResolver.query(uri, projection, null, null, null)
            ?: throw IOException("Could not read the backup folder.")
        cursor.use {
            if (!it.moveToFirst()) throw IOException("The backup folder or file no longer exists.")
            return Document(uri, it.getString(1), it.getInt(2),
                it.getString(3) == DocumentsContract.Document.MIME_TYPE_DIR)
        }
    }

    private fun children(context: Context, root: Uri): List<Document> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(root,
            DocumentsContract.getDocumentId(root))
        val cursor = context.contentResolver.query(children, projection, null, null, null)
            ?: throw IOException("Could not list the backup folder.")
        return cursor.use {
            val entries = mutableListOf<Document>()
            while (it.moveToNext()) {
                entries.add(Document(DocumentsContract.buildDocumentUriUsingTree(root, it.getString(0)),
                    it.getString(1), it.getInt(2),
                    it.getString(3) == DocumentsContract.Document.MIME_TYPE_DIR))
            }
            entries
        }
    }

    private fun child(context: Context, root: Uri, uri: String): Document =
        children(context, root).firstOrNull { it.uri.toString() == uri && !it.directory }
            ?: throw IOException("The backup file no longer exists in this folder.")

    private fun dispatch(context: Context, call: MethodCall): Any? {
        if (call.method == "freeSpace") return StatFs(context.filesDir.absolutePath).availableBytes
        val tree = call.argument<String>("tree") ?: throw IllegalArgumentException("Missing folder")
        if (call.method == "release") {
            val grant = context.contentResolver.persistedUriPermissions.firstOrNull { it.uri.toString() == tree }
            if (grant != null) {
                var flags = 0
                if (grant.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
                if (grant.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                context.contentResolver.releasePersistableUriPermission(grant.uri, flags)
            }
            return null
        }
        // Closing our own descriptor must still work after the provider grant
        // is revoked. No provider read/write is authorized by these branches.
        if (call.method == "closeCiphertext" || call.method == "closeCiphertextRead") {
            val uri = call.argument<String>("uri") ?: ""
            if (call.method == "closeCiphertext") {
                cipherWrites[uri]?.let {
                    if (it.first != tree) throw SecurityException("Export belongs to another folder")
                    cipherWrites.remove(uri)
                    it.second.close()
                }
            } else {
                cipherReads[uri]?.let {
                    if (it.first != tree) throw SecurityException("Export belongs to another folder")
                    cipherReads.remove(uri)
                    it.second.close()
                }
            }
            return null
        }
        val root = root(context, tree)
        return when (call.method) {
            "shareCiphertext" -> {
                val info = child(context, root, call.argument<String>("uri") ?: "")
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_STREAM, info.uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                null
            }
            "openCiphertext" -> {
                val name = call.argument<String>("name") ?: throw IllegalArgumentException("Missing filename")
                requireBackupFileName(name)
                if (children(context, root).any { it.name == name }) throw IOException("Filename is already in use")
                val uri = DocumentsContract.createDocument(context.contentResolver, root, "application/octet-stream", name)
                    ?: throw IOException("Could not create export")
                try {
                    val info = document(context, uri)
                    if (info.name != name || !canPublishBackup(info.flags)) throw IOException("Folder cannot publish exports")
                    val output = context.contentResolver.openOutputStream(uri, "w") ?: throw IOException("Could not write export")
                    cipherWrites[uri.toString()] = tree to output
                    info.json()
                } catch (e: Exception) {
                    try { DocumentsContract.deleteDocument(context.contentResolver, uri) } catch (_: Exception) {}
                    throw e
                }
            }
            "appendCiphertext" -> {
                val uri = call.argument<String>("uri") ?: ""
                val pending = cipherWrites[uri] ?: throw IOException("Export stream is closed")
                if (pending.first != tree) throw SecurityException("Export belongs to another folder")
                val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("Missing bytes")
                require(bytes.size <= 2 * 1024 * 1024) { "Export chunk is too large" }
                try { pending.second.write(bytes) } catch (e: Exception) {
                    cipherWrites.remove(uri)
                    try { pending.second.close() } catch (_: Exception) {}
                    throw e
                }
                null
            }
            "encryptCiphertext", "verifyCiphertext" -> {
                val uri = call.argument<String>("uri") ?: ""
                val gcm = OsbkGcm(call.argument<ByteArray>("key") ?: throw IllegalArgumentException("Missing key"),
                    call.argument<ByteArray>("nonce") ?: throw IllegalArgumentException("Missing nonce"),
                    call.argument<ByteArray>("header") ?: throw IllegalArgumentException("Missing header"))
                cipherBytes.set(0); cipherCancelled = false
                val progress = { n: Long -> cipherBytes.set(n) }
                val cancelled = { cipherCancelled }
                if (call.method == "encryptCiphertext") {
                    val pending = cipherWrites[uri] ?: throw IOException("Export stream is closed")
                    if (pending.first != tree) throw SecurityException("Export belongs to another folder")
                    val source = File(call.argument<String>("source") ?: throw IllegalArgumentException("Missing source"))
                    try {
                        source.inputStream().use { gcm.encrypt(it, pending.second, progress, cancelled) }
                    } catch (e: Exception) {
                        cipherWrites.remove(uri)
                        try { pending.second.close() } catch (_: Exception) {}
                        throw e
                    }
                } else {
                    val info = child(context, root, uri)
                    val stream = context.contentResolver.openInputStream(info.uri) ?: throw IOException("Could not read export")
                    stream.use { gcm.verify(it.buffered(OsbkGcm.CHUNK), progress, cancelled) }
                }
            }
            "probeCiphertext" -> {
                // Size plus SHA-256 of the first and last 64 KiB: a cheap identity check of a
                // published document against the fully verified one it was renamed from.
                val info = child(context, root, call.argument<String>("uri") ?: "")
                val pfd = context.contentResolver.openFileDescriptor(info.uri, "r") ?: throw IOException("Could not read export")
                pfd.use {
                    java.io.FileInputStream(it.fileDescriptor).channel.use { ch ->
                        val size = ch.size()
                        fun sha(at: Long): String {
                            val n = minOf(PROBE, size - at).toInt()
                            val buf = java.nio.ByteBuffer.allocate(n)
                            ch.position(at)
                            while (buf.hasRemaining() && ch.read(buf) >= 0) {}
                            if (buf.hasRemaining()) throw IOException("Could not read export")
                            return java.security.MessageDigest.getInstance("SHA-256").digest(buf.array()).joinToString("") { b -> "%02x".format(b) }
                        }
                        mapOf("size" to size, "head" to sha(0), "tail" to sha(maxOf(0L, size - PROBE)))
                    }
                }
            }
            "readCiphertext" -> {
                val uri = call.argument<String>("uri") ?: ""
                val pending = cipherReads[uri] ?: run {
                    val info = child(context, root, uri)
                    val stream = context.contentResolver.openInputStream(info.uri) ?: throw IOException("Could not read export")
                    (tree to stream).also { cipherReads[uri] = it }
                }
                if (pending.first != tree) throw SecurityException("Export belongs to another folder")
                try {
                    val bytes = ByteArray(256 * 1024)
                    val count = pending.second.read(bytes)
                    if (count < 0) {
                        cipherReads.remove(uri)
                        pending.second.close()
                        ByteArray(0)
                    } else bytes.copyOf(count)
                } catch (e: Exception) {
                    cipherReads.remove(uri)
                    try { pending.second.close() } catch (_: Exception) {}
                    throw e
                }
            }
            "list" -> children(context, root).filter { !it.directory }.map { it.json() }
            "write" -> {
                val name = call.argument<String>("name") ?: throw IllegalArgumentException("Missing filename")
                requireBackupFileName(name)
                if (children(context, root).any { it.name == name }) {
                    throw IOException("Backup filename is already in use.")
                }
                val source = File(call.argument<String>("source") ?: throw IllegalArgumentException("Missing source"))
                val uri = DocumentsContract.createDocument(context.contentResolver, root,
                    "application/octet-stream", name) ?: throw IOException("Could not create a backup file.")
                try {
                    val info = document(context, uri)
                    if (info.name != name || !canPublishBackup(info.flags)) {
                        throw IOException("This folder cannot publish backups safely. Choose another folder.")
                    }
                    val output = context.contentResolver.openOutputStream(uri, "w")
                        ?: throw IOException("Could not write the backup file.")
                    output.use { sink -> source.inputStream().use { it.copyTo(sink) } }
                    info.json()
                } catch (e: Exception) {
                    try { DocumentsContract.deleteDocument(context.contentResolver, uri) } catch (_: Exception) {}
                    throw e
                }
            }
            "rename" -> {
                val name = call.argument<String>("name") ?: throw IllegalArgumentException("Missing filename")
                requireBackupFileName(name)
                val info = child(context, root, call.argument<String>("uri") ?: "")
                if (children(context, root).any { it.name == name }) {
                    throw IOException("Backup filename is already in use.")
                }
                val renamed = DocumentsContract.renameDocument(context.contentResolver, info.uri, name)
                    ?: throw IOException("Could not publish the backup file.")
                val published = document(context, renamed)
                if (published.name != name) {
                    try { DocumentsContract.deleteDocument(context.contentResolver, renamed) } catch (_: Exception) {}
                    throw IOException("The folder changed the backup filename. Choose another folder.")
                }
                published.json()
            }
            "delete" -> {
                val info = child(context, root, call.argument<String>("uri") ?: "")
                if (!DocumentsContract.deleteDocument(context.contentResolver, info.uri)) {
                    throw IOException("Could not delete an old backup.")
                }
                null
            }
            else -> throw IllegalArgumentException("Unknown backup operation")
        }
    }
}

/** A staging file must support all three operations before any bytes are sent. */
internal fun canPublishBackup(flags: Int): Boolean {
    val required = DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
        DocumentsContract.Document.FLAG_SUPPORTS_RENAME or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
    return (flags and required) == required
}

internal fun requireBackupFileName(name: String) {
    require(name.isNotEmpty() && name != "." && name != ".." &&
        !name.contains('/') && !name.contains('\\') && !name.contains('\u0000'))
}
