package com.datacast.datacast

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private val bridge get() = (application as DataCastApplication).bridge

    override fun getCachedEngineId(): String = DataCastApplication.ENGINE_ID

    // Keep the engine (and the running server) when the activity goes away.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bridge.activity = this
    }

    override fun onDestroy() {
        if (bridge.activity === this) bridge.activity = null
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == NativeBridge.PICK_FOLDER_REQUEST) {
            bridge.onFolderPicked(if (resultCode == RESULT_OK) data?.data else null)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
