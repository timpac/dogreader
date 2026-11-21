package com.example.audiobook_app

import com.ryanheise.audioservice.AudioServiceActivity
import android.content.Intent
import android.support.v4.media.session.MediaControllerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val offline by lazy { OfflineBridge(this) }
    private var diagnostics: NativeMediaDiagnostics? = null
    private var diagnosticChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private val pendingShares = mutableListOf<String>()
    private var shareListenerReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        offline.attach(flutterEngine)
        val observer = NativeMediaDiagnostics.get(applicationContext)
        diagnostics = observer
        diagnosticChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dogreader/media_diagnostics")
        diagnosticChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        observer.start(MediaControllerCompat.getMediaController(this))
                        result.success(null)
                    }
                    "share" -> {
                        val text = call.arguments as? String
                        if (text == null || text.length > 600 * 1024) {
                            result.error("invalid_export", "Invalid diagnostic export", null)
                        } else {
                            observer.observe(MediaControllerCompat.getMediaController(this))
                            observer.export(text) { file, error ->
                                if (error != null) {
                                    result.error(error, "Could not export diagnostics", null)
                                } else {
                                    try {
                                        val uri = FileProvider.getUriForFile(this, "$packageName.media_diagnostics", file)
                                        val send = Intent(Intent.ACTION_SEND).apply {
                                            type = "text/plain"
                                            putExtra(Intent.EXTRA_STREAM, uri)
                                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        }
                                        startActivity(Intent.createChooser(send, "Share diagnostic log"))
                                        result.success(null)
                                    } catch (_: Exception) {
                                        result.error("share_unavailable", "Could not open sharing", null)
                                    }
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
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

    override fun onResume() {
        super.onResume()
        offline.onResume()
        diagnostics?.event("activity_resumed")
        diagnostics?.observe(MediaControllerCompat.getMediaController(this))
    }

    override fun onPause() {
        offline.onPause()
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        offline.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        offline.onActivityResult(requestCode, resultCode, data)
    }

    override fun onStop() {
        diagnostics?.event("activity_stopped")
        super.onStop()
    }

    override fun onDestroy() {
        diagnostics?.event("activity_destroyed")
        super.onDestroy()
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
        diagnosticChannel?.setMethodCallHandler(null)
        diagnosticChannel = null
        diagnostics = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        shareListenerReady = false
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
