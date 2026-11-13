package com.example.audiobook_app

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.pm.PackageManager
import org.json.JSONObject
import org.json.JSONArray
import android.content.Intent
import android.content.ContextWrapper
import android.content.IntentFilter
import android.media.MediaPlayer
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class OfflineBridge(private val activity: MainActivity) : ContextWrapper(activity) {
    private var resumed = false
    private var notificationReply: MethodChannel.Result? = null
    private var permissionDecision: Boolean? = null
    private var pendingExport: MethodChannel.Result? = null
    private var exportFile: File? = null

    fun attach(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dogreader3.kokoro")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "notificationPermission" -> {
                            if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) result.success(true)
                            else {
                                check(notificationReply == null) { "Permission request already active" }
                                notificationReply = result
                                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 42)
                            }
                        }
                        "startGeneration" -> {
                            check(resumed) { "Start generation from the visible probe" }
                            check(Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) { "Allow notifications before background generation" }
                            val existing = generationState()
                            if (existing?.optBoolean("active") == true) result.success(existing.getString("jobId"))
                            else {
                                val args = JSONObject(call.arguments as Map<*, *>)
                                val id = args.getString("id")
                                check(Regex("[A-Za-z0-9._-]{1,80}").matches(id))
                                val dir = File(filesDir, "generation-jobs/$id").apply { mkdirs() }
                                args.put("checkpointPath", File(dir, "chunks").absolutePath)
                                args.put("journalPath", File(dir, "worker-events.jsonl").absolutePath)
                                    .put("cancelPath", File(dir, "cancel").absolutePath)
                                    .put("reportPath", File(args.getString("output"), "benchmark-${args.getString("variant")}-$id.json").absolutePath)
                                    .put("experimentalBuild", if (Build.VERSION.SDK_INT >= 28) packageManager.getPackageInfo(packageName, 0).longVersionCode else packageManager.getPackageInfo(packageName, 0).versionCode.toLong())
                                File(dir, "cancel").delete()
                                File(dir, "request.json").writeText(args.toString())
                                GenerationService.writeState(this, JSONObject().put("jobId", id).put("active", true)
                                    .put("phase", "dispatching").put("message", "Starting foreground service")
                                    .put("startedElapsedMs", SystemClock.elapsedRealtime()).put("reportPath", args.getString("reportPath")))
                                try {
                                    startForegroundService(Intent(this, GenerationService::class.java).apply {
                                        action = GenerationService.START; putExtra("jobId", id)
                                    })
                                } catch (e: Exception) {
                                    GenerationService.writeState(this, JSONObject().put("jobId", id).put("active", false)
                                        .put("outcome", "error").put("message", e.message))
                                    throw e
                                }
                                result.success(id)
                            }
                        }
                        "generationStatus" -> result.success(generationState()?.toString())
                        "generationRecordings" -> result.success(try {
                            android.util.AtomicFile(File(filesDir, "generation-recordings.json")).openRead().use { it.readBytes().toString(Charsets.UTF_8) }
                        } catch (_: Exception) { null })
                        "cancelGeneration" -> {
                            val current = generationState()
                            if (current?.optBoolean("active") == true) startService(Intent(this, GenerationService::class.java).apply {
                                action = GenerationService.CANCEL; putExtra("jobId", current.getString("jobId"))
                            })
                            result.success(null)
                        }
                        "paths" -> result.success(mapOf(
                            "files" to filesDir.absolutePath,
                            "output" to File(filesDir, "offline-output").apply { mkdirs() }.absolutePath
                        ))
                        "keepAwake" -> {
                            if (call.arguments == true) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            result.success(null)
                        }
                        "telemetry" -> {
                            result.success(ProbeTelemetry.collect(this))
                        }
                        "export" -> {
                            check(pendingExport == null) { "An export is already open" }
                            val file = File(call.arguments as String)
                            check(file.isFile) { "Output file not found" }
                            exportFile = file
                            pendingExport = result
                            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = if (file.extension == "wav") "audio/wav" else "application/json"
                                putExtra(Intent.EXTRA_TITLE, file.name)
                            }, 41)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    if (call.method == "export") { pendingExport = null; exportFile = null }
                    result.error("probe", error.message, null)
                }
            }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != 41) return
        val reply = pendingExport ?: return
        try {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val stream = contentResolver.openOutputStream(data.data!!) ?: error("Cannot open destination")
                stream.use { target -> exportFile!!.inputStream().use { it.copyTo(target) } }
                reply.success(true)
            } else reply.success(false)
        } catch (error: Exception) { reply.error("export", error.message, null) }
        finally { pendingExport = null; exportFile = null }
    }

    private fun generationState(): JSONObject? {
        val value = GenerationService.readState(this) ?: return null
        val age = SystemClock.elapsedRealtime() - value.optLong("startedElapsedMs")
        val processes = (getSystemService(ACTIVITY_SERVICE) as ActivityManager).runningAppProcesses.orEmpty()
        if (value.optBoolean("active") && (age < 0 || age > 15000) && processes.none { it.processName == "$packageName:kokoro_generation" }) {
            value.put("active", false).put("outcome", "interrupted").put("phase", "interrupted")
                .put("message", "Generation process ended; no automatic restart").put("wakeLockHeld", false)
            GenerationService.writeState(this, value)
            val dir = File(filesDir, "generation-jobs/${value.getString("jobId")}")
            val report = JSONObject().put("completed", false).put("outcome", "interrupted")
                .put("results", JSONArray()).put("serviceState", value)
            for (kind in listOf("worker", "service")) {
                val events = JSONArray()
                File(dir, "$kind-events.jsonl").takeIf { it.exists() }?.forEachLine {
                    try { events.put(JSONObject(it)) } catch (_: Exception) {}
                }
                report.put("${kind}Events", events)
            }
            File(value.getString("reportPath")).writeText(report.toString(2))
            try {
                val request = JSONObject(File(dir, "request.json").readText())
                File(request.getString("output")).listFiles()?.filter {
                    it.name.contains(value.getString("jobId")) && it.name.endsWith(".part")
                }?.forEach { it.delete() }
            } catch (_: Exception) {}
        }
        return value
    }

    private fun visibility(value: Boolean) {
        val file = android.util.AtomicFile(File(filesDir, "generation-ui-visible.json"))
        try {
            val stream = file.startWrite()
            try { stream.write(JSONObject().put("visible", value).toString().toByteArray()); file.finishWrite(stream) }
            catch (e: Exception) { file.failWrite(stream) }
        } catch (_: Exception) {}
        sendBroadcast(Intent(GenerationService.VISIBILITY).setPackage(packageName).putExtra("visible", value))
    }

    fun onResume() {
        resumed = true
        permissionDecision?.let { notificationReply?.success(it); notificationReply = null; permissionDecision = null }
        visibility(true)
    }
    fun onPause() {
        resumed = false
        visibility(false)
    }
    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == 42) {
            permissionDecision = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (resumed) { notificationReply?.success(permissionDecision); notificationReply = null; permissionDecision = null }
        }
    }

}
