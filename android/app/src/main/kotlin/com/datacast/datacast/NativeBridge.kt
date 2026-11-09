package com.datacast.datacast

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Native side of `lib/services/platform_bridge.dart` (channel `datacast/native`). */
class NativeBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "datacast/native")
    private val storage = SafStorage(context)
    private val io = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())
    private var pendingPick: MethodChannel.Result? = null
    private var pendingFiles: MethodChannel.Result? = null

    var activity: Activity? = null
        set(value) {
            field = value
            applyKeepScreenOn()
        }
    private var keepScreenOn = false

    private fun applyKeepScreenOn() {
        val window = activity?.window ?: return
        if (keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    init {
        channel.setMethodCallHandler(this)
        instance = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "pickFiles" -> pickFiles(result)
            "hasDocAccess" -> background(result) { storage.hasDocAccess(uriArg(call)) }
            "docStat" -> background(result) { storage.docStat(uriArg(call)) }
            "docOpenFd" -> background(result) { storage.docOpenFd(uriArg(call)) }
            "docReadChunk" -> background(result) {
                storage.docReadChunk(
                    uriArg(call),
                    (call.argument<Number>("offset") ?: 0).toLong(),
                    call.argument<Int>("length") ?: 0,
                )
            }
            "deviceName" -> result.success(deviceName())
            "startService" -> {
                requestNotificationPermission()
                SharingService.start(context, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "stopService" -> {
                SharingService.stop(context)
                result.success(null)
            }
            "setKeepScreenOn" -> {
                keepScreenOn = call.argument<Boolean>("on") == true
                applyKeepScreenOn()
                result.success(null)
            }
            "hasFolderAccess" -> background(result) { storage.hasAccess(uriArg(call)) }
            "list" -> background(result) { storage.list(uriArg(call), pathArg(call)) }
            "stat" -> background(result) { storage.stat(uriArg(call), pathArg(call)) }
            "openFd" -> background(result) { storage.openFd(uriArg(call), pathArg(call)) }
            "closeFd" -> background(result) { storage.closeFd(call.argument<Int>("fd")!!); null }
            "readChunk" -> background(result) {
                storage.readChunk(
                    uriArg(call), pathArg(call),
                    (call.argument<Number>("offset") ?: 0).toLong(),
                    call.argument<Int>("length") ?: 0,
                )
            }
            else -> result.notImplemented()
        }
    }

    /** Tells Dart the user tapped "Stop" in the notification. */
    fun notifyStopRequested() {
        main.post { channel.invokeMethod("stopRequested", null) }
    }

    // ---------------------------------------------------------------- picker

    private fun pickFolder(result: MethodChannel.Result) {
        val a = activity ?: return result.error("no_activity", "App is not in the foreground", null)
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        @Suppress("DEPRECATION")
        a.startActivityForResult(intent, PICK_FOLDER_REQUEST)
    }

    private fun pickFiles(result: MethodChannel.Result) {
        val a = activity ?: return result.error("no_activity", "App is not in the foreground", null)
        pendingFiles?.success(null)
        pendingFiles = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        @Suppress("DEPRECATION")
        a.startActivityForResult(intent, PICK_FILES_REQUEST)
    }

    fun onFilesPicked(data: Intent?) {
        val result = pendingFiles ?: return
        pendingFiles = null
        val uris = ArrayList<Uri>()
        val clip = data?.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add)
        } else {
            data?.data?.let(uris::add)
        }
        if (uris.isEmpty()) return result.success(null)
        io.execute {
            try {
                val files = uris.mapNotNull { uri ->
                    try {
                        storage.takeDocPermission(uri)
                    } catch (_: SecurityException) {
                        // Some providers don't offer persistable access; it still works until restart.
                    }
                    storage.docStat(uri)?.let { it + ("uri" to uri.toString()) }
                }
                main.post { result.success(files) }
            } catch (e: Exception) {
                main.post { result.error("pick_failed", e.message, null) }
            }
        }
    }

    fun onFolderPicked(uri: Uri?) {
        val result = pendingPick ?: return
        pendingPick = null
        if (uri == null) return result.success(null)
        io.execute {
            try {
                storage.takePermission(uri)
                val name = storage.displayName(uri) ?: "Shared folder"
                main.post { result.success(mapOf("uri" to uri.toString(), "name" to name)) }
            } catch (e: Exception) {
                main.post { result.error("pick_failed", e.message, null) }
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    private fun deviceName(): String {
        val name = try {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        } catch (_: Exception) {
            null
        }
        return name?.takeIf { it.isNotBlank() } ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        val a = activity ?: return
        if (a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4243)
        }
    }

    private fun uriArg(call: MethodCall): Uri = Uri.parse(call.argument<String>("uri")!!)
    private fun pathArg(call: MethodCall): String = call.argument<String>("path") ?: "/"

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("storage_error", e.message, null) }
            }
        }
    }

    companion object {
        const val PICK_FOLDER_REQUEST = 4242
        const val PICK_FILES_REQUEST = 4244

        @Volatile
        var instance: NativeBridge? = null
            private set
    }
}
