package com.datacast.datacast

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the Flutter engine so it outlives the activity. The HTTP server runs in
 * Dart; while [SharingService] keeps the process alive, closing or swiping
 * away the app does not stop sharing.
 */
class DataCastApplication : Application() {
    lateinit var bridge: NativeBridge
        private set

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        bridge = NativeBridge(this, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "datacast_main"
    }
}
