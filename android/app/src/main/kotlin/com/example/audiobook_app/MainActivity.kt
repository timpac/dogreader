package com.example.audiobook_app

import com.ryanheise.audioservice.AudioServiceActivity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var freePressChannel: MethodChannel? = null
    private var pendingFreePress: MethodChannel.Result? = null
    private var shareChannel: MethodChannel? = null
    private val pendingShares = mutableListOf<String>()
    private var shareListenerReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        acceptShare(intent)
        if (packageName == "com.example.audiobook_app.experimental") {
            freePressChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dogreader/freepress")
            freePressChannel?.setMethodCallHandler { call, result ->
                if (call.method == "openArticle") {
                    if (pendingFreePress != null) {
                        result.error("BUSY", "An article is already open.", null)
                    } else {
                        pendingFreePress = result
                        val articleIntent = Intent().setClassName(this, "com.example.audiobook_app.FreePressLoginActivity")
                        articleIntent.putExtra("articleUrl", call.argument<String>("url"))
                        @Suppress("DEPRECATION")
                        startActivityForResult(articleIntent, 0x4650)
                    }
                } else result.notImplemented()
            }
        }
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

    @Deprecated("Legacy result callback used by the Flutter host")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 0x4650) {
            val reply = pendingFreePress
            pendingFreePress = null
            reply?.success(if (resultCode == RESULT_OK) data?.getStringExtra("article") else null)
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
        pendingFreePress?.success(null)
        pendingFreePress = null
        freePressChannel?.setMethodCallHandler(null)
        freePressChannel = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        shareListenerReady = false
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
