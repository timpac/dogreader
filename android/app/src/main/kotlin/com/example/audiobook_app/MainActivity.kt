package com.example.audiobook_app

import com.ryanheise.audioservice.AudioServiceActivity
import android.content.Intent
import android.support.v4.media.session.MediaControllerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var diagnostics: NativeMediaDiagnostics? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val observer = NativeMediaDiagnostics.get(applicationContext)
        diagnostics = observer
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dogreader/media_diagnostics")
            .setMethodCallHandler { call, result ->
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
    }

    override fun onResume() {
        super.onResume()
        diagnostics?.event("activity_resumed")
        diagnostics?.observe(MediaControllerCompat.getMediaController(this))
    }

    override fun onStop() {
        diagnostics?.event("activity_stopped")
        super.onStop()
    }

    override fun onDestroy() {
        diagnostics?.event("activity_destroyed")
        super.onDestroy()
    }
}
