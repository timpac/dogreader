package com.dogreader.kokoro_probe

import android.app.Activity
import android.content.Intent
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

class MainActivity : FlutterActivity() {
    private var player: MediaPlayer? = null
    private var pendingExport: MethodChannel.Result? = null
    private var exportFile: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dogreader.kokoro_probe")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "paths" -> result.success(mapOf(
                            "files" to filesDir.absolutePath,
                            "output" to (getExternalFilesDir(null) ?: filesDir).absolutePath
                        ))
                        "keepAwake" -> {
                            if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            result.success(null)
                        }
                        "telemetry" -> {
                            val memory = Debug.MemoryInfo()
                            Debug.getMemoryInfo(memory)
                            val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            val manager = getSystemService(BATTERY_SERVICE) as BatteryManager
                            val power = getSystemService(POWER_SERVICE) as PowerManager
                            val charge = manager.getLongProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
                            val energy = manager.getLongProperty(BatteryManager.BATTERY_PROPERTY_ENERGY_COUNTER)
                            result.success(mapOf(
                                "elapsedRealtimeMs" to SystemClock.elapsedRealtime(),
                                "cpuMs" to Process.getElapsedCpuTime(),
                                "pssKb" to memory.totalPss,
                                "batteryTemperatureDeciC" to battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1),
                                "batteryLevel" to battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
                                "batteryScale" to battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1),
                                "plugged" to battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1),
                                "voltageMv" to battery?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1),
                                "chargeUah" to if (charge == Long.MIN_VALUE) null else charge,
                                "energyNwh" to if (energy == Long.MIN_VALUE) null else energy,
                                "thermalStatus" to if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else null,
                                "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL,
                                "sdk" to Build.VERSION.SDK_INT, "fingerprint" to Build.FINGERPRINT,
                                "supportedAbis" to Build.SUPPORTED_ABIS.toList()
                            ))
                        }
                        "play" -> {
                            stopPlayer()
                            player = MediaPlayer().apply {
                                setDataSource(call.arguments as String)
                                setOnCompletionListener { stopPlayer() }
                                prepare()
                                start()
                            }
                            result.success(null)
                        }
                        "stop" -> { stopPlayer(); result.success(null) }
                        "export" -> {
                            check(pendingExport == null) { "An export is already open" }
                            val file = File(call.arguments as String)
                            check(file.isFile) { "Output file not found" }
                            exportFile = file
                            pendingExport = result
                            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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

    private fun stopPlayer() { player?.release(); player = null }
    override fun onDestroy() { stopPlayer(); super.onDestroy() }
}
