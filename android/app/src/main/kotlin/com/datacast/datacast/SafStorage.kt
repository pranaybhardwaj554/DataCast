package com.datacast.datacast

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.OpenableColumns
import java.util.concurrent.ConcurrentHashMap

/**
 * Read-only access to a folder picked with ACTION_OPEN_DOCUMENT_TREE.
 *
 * Share paths (`/Photos/a.jpg`) are resolved to document ids by walking the
 * tree by display name; results are cached because SAF queries are slow.
 */
class SafStorage(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val idCache = ConcurrentHashMap<String, String>()
    private val thumbs = Thumbnails(context)

    fun thumbnail(tree: Uri, path: String, px: Int): ByteArray? {
        val id = resolve(tree, path) ?: return null
        return docThumbnail(DocumentsContract.buildDocumentUriUsingTree(tree, id), px)
    }

    fun docThumbnail(doc: Uri, px: Int): ByteArray? {
        val stat = docStat(doc) ?: return null
        return thumbs.get(doc, stat, px)
    }

    fun takePermission(tree: Uri) {
        resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    fun hasAccess(tree: Uri): Boolean =
        resolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }

    // ------------------------------------------------ individually picked files

    fun takeDocPermission(doc: Uri) {
        resolver.takePersistableUriPermission(doc, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    fun hasDocAccess(doc: Uri): Boolean {
        if (resolver.persistedUriPermissions.any { it.uri == doc && it.isReadPermission }) return true
        return try {
            resolver.query(doc, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { true } ?: false
        } catch (_: Exception) {
            false
        }
    }

    /** {name, size, mime, modified} for one document, or null if it's gone. */
    fun docStat(doc: Uri): Map<String, Any?>? = try {
        resolver.query(doc, null, null, null, null)?.use { c ->
            if (!c.moveToFirst()) return@use null
            fun col(name: String) = c.getColumnIndex(name)
            val nameCol = col(OpenableColumns.DISPLAY_NAME)
            val sizeCol = col(OpenableColumns.SIZE)
            val modCol = col(Document.COLUMN_LAST_MODIFIED)
            mapOf(
                "name" to ((if (nameCol >= 0) c.getString(nameCol) else null)
                    ?: doc.lastPathSegment ?: "file"),
                "size" to if (sizeCol >= 0 && !c.isNull(sizeCol)) c.getLong(sizeCol) else 0L,
                "mime" to resolver.getType(doc),
                "modified" to if (modCol >= 0 && !c.isNull(modCol)) c.getLong(modCol) else 0L,
            )
        }
    } catch (_: Exception) {
        null
    }

    fun docOpenFd(doc: Uri): Int? = resolver.openFileDescriptor(doc, "r")?.detachFd()

    fun docReadChunk(doc: Uri, offset: Long, length: Int): ByteArray =
        resolver.openInputStream(doc)?.use { readRange(it, offset, length) } ?: ByteArray(0)

    // --------------------------------------------------------- picked folders

    fun displayName(tree: Uri): String? {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return resolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }

    fun list(tree: Uri, path: String): List<Map<String, Any?>>? {
        val dirId = resolve(tree, path) ?: return null
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dirId)
        val out = ArrayList<Map<String, Any?>>()
        resolver.query(children, COLUMNS, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val row = row(c) ?: continue
                val childPath = if (path == "/") "/${row["name"]}" else "$path/${row["name"]}"
                idCache.putIfAbsent(key(tree, childPath), c.getString(0))
                out.add(row)
            }
        } ?: return null
        return out
    }

    fun stat(tree: Uri, path: String): Map<String, Any?>? {
        stat(tree, path, retry = true)?.let { return it }
        return null
    }

    private fun stat(tree: Uri, path: String, retry: Boolean): Map<String, Any?>? {
        val id = resolve(tree, path) ?: return null
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val row = try {
            resolver.query(doc, COLUMNS, null, null, null)?.use { c -> if (c.moveToFirst()) row(c) else null }
        } catch (_: Exception) {
            null
        }
        if (row == null && retry) {
            // Stale cache (file renamed or deleted): forget and walk again.
            idCache.keys.removeIf { it.startsWith("$tree|") }
            return stat(tree, path, retry = false)
        }
        return row
    }

    fun openFd(tree: Uri, path: String): Int? {
        val id = resolve(tree, path) ?: return null
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        return resolver.openFileDescriptor(doc, "r")?.detachFd()
    }

    fun closeFd(fd: Int) {
        ParcelFileDescriptor.adoptFd(fd).close()
    }

    fun readChunk(tree: Uri, path: String, offset: Long, length: Int): ByteArray {
        val id = resolve(tree, path) ?: return ByteArray(0)
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        return resolver.openInputStream(doc)?.use { readRange(it, offset, length) } ?: ByteArray(0)
    }

    private fun readRange(input: java.io.InputStream, offset: Long, length: Int): ByteArray {
        var skipped = 0L
        while (skipped < offset) {
            val n = input.skip(offset - skipped)
            if (n <= 0) return ByteArray(0)
            skipped += n
        }
        val buf = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(buf, read, length - read)
            if (n < 0) break
            read += n
        }
        return if (read == length) buf else buf.copyOf(read)
    }

    private fun resolve(tree: Uri, path: String): String? {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        if (path == "/" || path.isEmpty()) return rootId
        idCache[key(tree, path)]?.let { return it }
        var current = rootId
        var currentPath = ""
        for (segment in path.trim('/').split('/')) {
            currentPath += "/$segment"
            val cached = idCache[key(tree, currentPath)]
            if (cached != null) {
                current = cached
                continue
            }
            current = findChild(tree, current, segment) ?: return null
            idCache[key(tree, currentPath)] = current
        }
        return current
    }

    private fun findChild(tree: Uri, parentId: String, name: String): String? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        resolver.query(
            children,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name) return c.getString(0)
            }
        }
        return null
    }

    private fun row(c: android.database.Cursor): Map<String, Any?>? {
        val name = c.getString(1) ?: return null
        val mime = c.getString(2)
        return mapOf(
            "name" to name,
            "isDir" to (mime == Document.MIME_TYPE_DIR),
            "mime" to mime,
            "size" to if (c.isNull(3)) 0L else c.getLong(3),
            "modified" to if (c.isNull(4)) 0L else c.getLong(4),
        )
    }

    private fun key(tree: Uri, path: String) = "$tree|$path"

    companion object {
        private val COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
        )
    }
}
