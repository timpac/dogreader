package com.example.audiobook_app

import com.ryanheise.audioservice.AudioServiceActivity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var shareChannel: MethodChannel? = null
    private val pendingShares = mutableListOf<String>()
    private var shareListenerReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        acceptShare(intent)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dogreader/article_share")
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "takePendingTexts") {
                shareListenerReady = true
                result.success(pendingShares.toList())
                pendingShares.clear()
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptShare(intent)
    }

    private fun acceptShare(shared: Intent?) {
        if (shared?.action != Intent.ACTION_SEND || shared.type != "text/plain") return
        val text = shared.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: return
        shared.removeExtra(Intent.EXTRA_TEXT)
        if (shareListenerReady) shareChannel?.invokeMethod("sharedText", text)
        else pendingShares.add(text)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        shareListenerReady = false
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
