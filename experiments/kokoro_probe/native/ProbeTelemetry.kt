package com.dogreader.kokoro_probe

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.*

object ProbeTelemetry {
    fun collect(context: Context): Map<String, Any?> {
        val memory = Debug.MemoryInfo()
        Debug.getMemoryInfo(memory)
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val manager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val charge = manager.getLongProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        val energy = manager.getLongProperty(BatteryManager.BATTERY_PROPERTY_ENERGY_COUNTER)
        return mapOf(
            "elapsedRealtimeMs" to SystemClock.elapsedRealtime(), "cpuMs" to Process.getElapsedCpuTime(),
            "pssKb" to memory.totalPss, "pid" to Process.myPid(), "interactive" to power.isInteractive,
            "deviceIdleMode" to power.isDeviceIdleMode, "batteryOptimizationExempt" to power.isIgnoringBatteryOptimizations(context.packageName),
            "batteryTemperatureDeciC" to battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1),
            "batteryLevel" to battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
            "batteryScale" to battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1),
            "plugged" to battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1),
            "voltageMv" to battery?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1),
            "chargeUah" to if (charge == Long.MIN_VALUE) null else charge,
            "energyNwh" to if (energy == Long.MIN_VALUE) null else energy,
            "thermalStatus" to if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else null,
            "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL, "sdk" to Build.VERSION.SDK_INT,
            "fingerprint" to Build.FINGERPRINT, "supportedAbis" to Build.SUPPORTED_ABIS.toList())
    }
}
