package com.example.audiobook_app

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.*
import android.util.AtomicFile
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Owns the headless engine and inference process, never the Activity. */
class GenerationService : Service() {
    companion object {
        const val START = "com.dogreader.v3.GENERATE"
        const val CANCEL = "com.dogreader.v3.CANCEL"
        const val VISIBILITY = "com.dogreader.v3.VISIBILITY"
        const val CHANNEL = "kokoro_generation"
        const val NOTIFICATION = 148
        const val MAX_MS = 6 * 60 * 60 * 1000L
        fun stateFile(context: Context) = File(context.filesDir, "generation-state.json")
        fun readState(context: Context): JSONObject? = try {
            JSONObject(AtomicFile(stateFile(context)).openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        } catch (_: Exception) { null }
        fun writeState(context: Context, value: JSONObject) {
            val file = AtomicFile(stateFile(context))
            val stream = file.startWrite()
            try { stream.write(value.toString().toByteArray()); file.finishWrite(stream) }
            catch (e: Exception) { file.failWrite(stream); throw e }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var request: JSONObject? = null
    private var state = JSONObject()
    private var active = false
    private var receiverRegistered = false
    private var uiVisible = true
    private lateinit var jobDir: File
    private val events = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!active) return
            if (intent?.action == VISIBILITY) uiVisible = intent.getBooleanExtra("visible", false)
            record(intent?.action ?: "unknown")
        }
    }

    override fun onBind(intent: Intent?) = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == CANCEL) {
            if (active && intent.getStringExtra("jobId") == state.optString("jobId")) cancel()
            else if (!active) stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action != START) { if (!active) stopSelf(); return START_NOT_STICKY }
        if (active) return START_NOT_STICKY
        try {
            val id = intent.getStringExtra("jobId") ?: error("Missing job ID")
            check(Regex("[A-Za-z0-9._-]{1,80}").matches(id))
            jobDir = File(filesDir, "generation-jobs/$id")
            request = JSONObject(File(jobDir, "request.json").readText())
            state = JSONObject().put("jobId", id).put("active", true).put("phase", "starting")
                .put("message", "Starting offline generation").put("pid", Process.myPid())
                .put("startedElapsedMs", SystemClock.elapsedRealtime())
                .put("reportPath", request!!.getString("reportPath"))
            request!!.optJSONObject("chapter")?.let { state.put("chapter", it) }
            active = true
            val notifications = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Dogreader 3.0 offline narration", NotificationManager.IMPORTANCE_LOW))
            check(notifications.areNotificationsEnabled() && notifications.getNotificationChannel(CHANNEL).importance != NotificationManager.IMPORTANCE_NONE) {
                "Enable Offline narration notifications in Android settings"
            }
            val notification = notification()
            when {
                Build.VERSION.SDK_INT >= 35 -> startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING)
                Build.VERSION.SDK_INT >= 29 -> startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                else -> startForeground(NOTIFICATION, notification)
            }
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:LocalGeneration").apply {
                    setReferenceCounted(false); acquire(MAX_MS)
                }
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT); addAction(VISIBILITY)
            }
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(events, filter, RECEIVER_NOT_EXPORTED)
            else registerReceiver(events, filter)
            receiverRegistered = true
            persist(); record("serviceStarted")
            handler.postDelayed({ if (active) terminal("timeout", "Generation session time limit", true) }, MAX_MS - 60000)
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            engine = FlutterEngine(applicationContext, null, false)
            MethodChannel(engine!!.dartExecutor.binaryMessenger, "dogreader.kokoro_generation")
                .setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "request" -> result.success(request.toString())
                            "telemetry" -> result.success(ProbeTelemetry.collect(this) + mapOf(
                                "uiVisible" to uiVisible, "wakeLockHeld" to (wakeLock?.isHeld == true)))
                            "progress" -> {
                                if (active) {
                                    val event = JSONObject(call.arguments as String)
                                    for (key in listOf("phase", "run", "chunk", "totalChunks", "completedChunks", "status")) {
                                        if (state.optString("phase") != "cancelling" && event.has(key)) state.put(if (key == "status") "message" else key, event.get(key))
                                    }
                                    state.put("lastWorkerEvent", event)
                                    persist(); record("progress", event); notifications.notify(NOTIFICATION, notification())
                                }
                                result.success(null)
                            }
                            "finished" -> {
                                val event = JSONObject(call.arguments as String)
                                result.success(null)
                                handler.post { if (active) terminal(event.getString("outcome"), event.getString("message"), false) }
                            }
                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        result.error("generation", e.message, null)
                        if (active) terminal("error", e.message ?: "Service error", true)
                    }
                }
            engine!!.lifecycleChannel.appIsResumed()
            engine!!.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "generationMain"))
        } catch (e: Exception) {
            if (active) terminal("error", e.message ?: "Cannot start foreground generation", true)
            else stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val cancel = PendingIntent.getService(this, 1, Intent(this, GenerationService::class.java).apply {
            action = CANCEL; putExtra("jobId", state.optString("jobId"))
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val total = state.optInt("totalChunks", 0)
        val builder = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Dogreader 3.0 • Kokoro Offline").setContentText(state.optString("message"))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setProgress(total, state.optInt("completedChunks", 0), total == 0)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .addAction(Notification.Action.Builder(null, "Cancel", cancel).build())
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return builder.build()
    }

    private fun persist() {
        state.put("updatedElapsedMs", SystemClock.elapsedRealtime())
            .put("wakeLockHeld", wakeLock?.isHeld == true)
        writeState(this, state)
    }

    private fun record(name: String, detail: JSONObject? = null) {
        // Persisted Activity state also covers a pause that raced service startup.
        try { uiVisible = JSONObject(AtomicFile(File(filesDir, "generation-ui-visible.json")).openRead().use {
            it.readBytes().toString(Charsets.UTF_8)
        }).getBoolean("visible") } catch (_: Exception) {}
        val power = getSystemService(POWER_SERVICE) as PowerManager
        val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        val event = JSONObject().put("event", name).put("unixMs", System.currentTimeMillis())
            .put("elapsedRealtimeMs", SystemClock.elapsedRealtime()).put("uptimeMs", SystemClock.uptimeMillis())
            .put("interactive", power.isInteractive).put("keyguardLocked", keyguard.isKeyguardLocked)
            .put("deviceIdleMode", power.isDeviceIdleMode).put("batteryOptimizationExempt", power.isIgnoringBatteryOptimizations(packageName))
            .put("uiVisible", uiVisible).put("wakeLockHeld", wakeLock?.isHeld == true).put("pid", Process.myPid())
        if (detail != null) event.put("worker", detail)
        File(jobDir, "service-events.jsonl").appendText(event.toString() + "\n")
    }

    private fun cancel() {
        File(jobDir, "cancel").writeText("cancelled")
        state.put("phase", "cancelling").put("message", "Cancelling after current chunk (maximum 15 seconds)")
        persist(); record("cancelRequested")
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
        handler.postDelayed({ if (active) terminal("cancelled", "Cancelled; inference process stopped", true) }, 15000)
    }

    private fun lines(file: File): JSONArray = JSONArray().also { output ->
        if (file.exists()) file.forEachLine { line -> try { output.put(JSONObject(line)) } catch (_: Exception) {} }
    }

    private fun terminal(outcome: String, message: String, forced: Boolean) {
        active = false
        handler.removeCallbacksAndMessages(null)
        if (wakeLock?.isHeld == true) wakeLock!!.release()
        state.put("active", false).put("outcome", outcome).put("phase", outcome)
            .put("message", message).put("forcedProcessStop", forced)
        persist(); record("serviceFinished")
        val report = File(state.getString("reportPath"))
        val summary = try { JSONObject(report.readText()) } catch (_: Exception) { JSONObject().put("results", JSONArray()) }
        summary.put("completed", outcome == "completed").put("outcome", outcome)
            .put("status", message).put("serviceState", state)
            .put("workerEvents", lines(File(jobDir, "worker-events.jsonl")))
            .put("serviceEvents", lines(File(jobDir, "service-events.jsonl")))
        val atomic = AtomicFile(report)
        val stream = atomic.startWrite()
        try { stream.write(summary.toString(2).toByteArray()); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream) }
        val indexFile = AtomicFile(File(filesDir, "generation-recordings.json"))
        val index = try { JSONObject(indexFile.openRead().use { it.readBytes().toString(Charsets.UTF_8) }) } catch (_: Exception) { JSONObject() }
        val results = summary.optJSONArray("results") ?: JSONArray()
        for (i in 0 until results.length()) {
            val item = results.getJSONObject(i)
            if (File(item.getString("path")).isFile) {
                item.put("report", report.absolutePath)
                index.put(item.getString("modelVariant"), item)
            }
        }
        val saved = indexFile.startWrite()
        try { saved.write(index.toString().toByteArray()); indexFile.finishWrite(saved) }
        catch (e: Exception) { indexFile.failWrite(saved) }
        request?.let {
            File(it.getString("output")).listFiles()?.filter { file ->
                file.name.contains(state.getString("jobId")) && file.name.endsWith(".part")
            }?.forEach { file -> file.delete() }
        }
        if (outcome == "completed" && results.length() == 1) {
            request?.optJSONObject("chapter")?.let { chapter ->
                val item = JSONObject(chapter.toString())
                    .put("result", results.getJSONObject(0)).put("report", report.absolutePath)
                    .put("jobId", state.getString("jobId"))
                val completion = AtomicFile(File(jobDir, "complete.json"))
                val output = completion.startWrite()
                try { output.write(item.toString().toByteArray()); completion.finishWrite(output) }
                catch (e: Exception) { completion.failWrite(output); throw e }
                val chapters = AtomicFile(File(filesDir, "offline-recordings.json"))
                val savedChapters = try { JSONObject(chapters.openRead().use { it.readBytes().toString(Charsets.UTF_8) }) }
                    catch (_: Exception) { JSONObject() }
                savedChapters.put(chapter.getString("key"), item)
                val streamChapters = chapters.startWrite()
                try { streamChapters.write(savedChapters.toString().toByteArray()); chapters.finishWrite(streamChapters) }
                catch (e: Exception) { chapters.failWrite(streamChapters); throw e }
            }
        }
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        if (forced) killOwnProcess()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        if (active) terminal("timeout", "Android foreground-service time quota reached", true)
        else stopSelf()
    }

    override fun onDestroy() {
        if (active) { terminal("interrupted", "Generation service stopped unexpectedly", true); return }
        if (receiverRegistered) unregisterReceiver(events)
        if (wakeLock?.isHeld == true) wakeLock!!.release()
        engine?.destroy(); engine = null
        super.onDestroy()
        killOwnProcess()
    }

    private fun killOwnProcess() {
        // Never kill the UI process if a future manifest is accidentally changed.
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val name = if (Build.VERSION.SDK_INT >= 28) Application.getProcessName()
            else manager.runningAppProcesses?.find { it.pid == Process.myPid() }?.processName
        if (name == "$packageName:kokoro_generation")
            Process.killProcess(Process.myPid())
    }
}
