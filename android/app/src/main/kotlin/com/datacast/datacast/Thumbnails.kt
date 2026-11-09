package com.datacast.datacast

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/**
 * JPEG thumbnails for documents, cached in the app's cache directory keyed by
 * URI, modification time, size and pixel size.
 */
class Thumbnails(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val dir by lazy { File(context.cacheDir, "thumbs").apply { mkdirs() } }
    @Volatile private var writesSinceTrim = 0

    fun get(doc: Uri, stat: Map<String, Any?>, px: Int): ByteArray? {
        val key = sha1("$doc|${stat["modified"]}|${stat["size"]}|$px")
        val cached = File(dir, "$key.jpg")
        if (cached.exists()) {
            cached.setLastModified(System.currentTimeMillis())
            return cached.readBytes()
        }
        val mime = (stat["mime"] as? String) ?: resolver.getType(doc) ?: ""
        val bitmap = load(doc, mime, px) ?: return null
        val bytes = ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
            out.toByteArray()
        }
        bitmap.recycle()
        try {
            cached.writeBytes(bytes)
            if (++writesSinceTrim >= 50) {
                writesSinceTrim = 0
                trim()
            }
        } catch (_: Exception) {
        }
        return bytes
    }

    private fun load(doc: Uri, mime: String, px: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                return fit(resolver.loadThumbnail(doc, Size(px, px), null), px)
            } catch (_: Exception) {
                // fall through to manual decoding for images
            }
        }
        if (!mime.startsWith("image/")) return null
        return try {
            decodeImage(doc, px)
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    private fun decodeImage(doc: Uri, px: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(doc)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= px) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(doc)?.use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
        val rotation = try {
            resolver.openInputStream(doc)?.use {
                when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } ?: 0f
        } catch (_: Exception) {
            0f
        }
        val rotated = if (rotation == 0f) decoded else {
            val m = Matrix().apply { postRotate(rotation) }
            Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, m, true).also {
                if (it !== decoded) decoded.recycle()
            }
        }
        return fit(rotated, px)
    }

    /** Scales down so the longest side is at most [px]. */
    private fun fit(b: Bitmap, px: Int): Bitmap {
        val longest = maxOf(b.width, b.height)
        if (longest <= px) return b
        val scale = px.toFloat() / longest
        val scaled = Bitmap.createScaledBitmap(
            b, (b.width * scale).toInt().coerceAtLeast(1), (b.height * scale).toInt().coerceAtLeast(1), true,
        )
        if (scaled !== b) b.recycle()
        return scaled
    }

    /** Keeps the cache under ~100 MB, dropping least recently used first. */
    private fun trim() {
        val files = dir.listFiles() ?: return
        var total = files.sumOf { it.length() }
        val limit = 100L * 1024 * 1024
        if (total <= limit) return
        for (f in files.sortedBy { it.lastModified() }) {
            total -= f.length()
            f.delete()
            if (total <= limit * 8 / 10) break
        }
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
}
