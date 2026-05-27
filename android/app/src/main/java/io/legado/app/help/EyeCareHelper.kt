package io.legado.app.help

import android.app.Activity
import android.app.Application
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import io.legado.app.constant.PreferKey
import io.legado.app.ui.book.read.ReadBookActivity
import io.legado.app.utils.getPrefBoolean
import splitties.init.appCtx
import java.lang.ref.WeakReference
import java.util.Calendar
import kotlin.math.abs

/**
 * 万象书屋 D-18~D-22: 护眼模式 — 暖色滤镜 + 环境光/节律 + 阅读联动.
 * 强度由 lux + 时段自动决定, 不提供手动档位.
 */
object EyeCareHelper {

    private const val OVERLAY_TAG = "wanxiang_eye_care_overlay"
    private const val LOG_TAG = "EyeCareHelper"
    private const val READER_OVERLAY_FACTOR = 0.35f
    private const val DEFAULT_ALPHA = 0x4D
    private const val BASE_RGB = 0xFAF0DC
    private const val DEEP_NIGHT_RGB = 0xFFE0B3

    @Volatile
    private var currentAlpha: Int = DEFAULT_ALPHA

    fun isEnabled(): Boolean = appCtx.getPrefBoolean(PreferKey.eyeCareMode, false)

    internal fun updateAlphaFromLightSensor(newAlpha: Int) {
        if (abs(newAlpha - currentAlpha) < 0x10) return
        currentAlpha = newAlpha.coerceIn(0x1A, 0x8C)
        EyeCareLifecycleCallback.currentActivity?.let { apply(it) }
        io.legado.app.utils.LogUtils.d(LOG_TAG, "alpha auto-adjusted to ${currentAlpha.toString(16)}")
    }

    fun apply(activity: Activity) {
        val enabled = isEnabled()
        val root = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        val existing = root.findViewWithTag<View>(OVERLAY_TAG)
        if (enabled) {
            val alpha = effectiveAlpha(activity)
            val baseRgb = autoBaseRgb(LightSensorMonitor.lastLux)
            val color = (alpha shl 24) or (baseRgb and 0xFFFFFF)
            if (existing == null) {
                val overlay = View(activity).apply {
                    tag = OVERLAY_TAG
                    setBackgroundColor(color)
                    isClickable = false
                    isFocusable = false
                    layoutParams = android.widget.FrameLayout.LayoutParams(
                        android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                        android.widget.FrameLayout.LayoutParams.MATCH_PARENT
                    )
                }
                root.addView(overlay)
                overlay.bringToFront()
            } else {
                existing.setBackgroundColor(color)
                existing.visibility = View.VISIBLE
                existing.bringToFront()
            }
            LightSensorMonitor.start()
        } else {
            existing?.let { root.removeView(it) }
            LightSensorMonitor.stop()
        }
    }

    private fun effectiveAlpha(activity: Activity): Int {
        val base = currentAlpha
        return if (activity is ReadBookActivity) {
            (base * READER_OVERLAY_FACTOR).toInt().coerceAtLeast(0x14)
        } else {
            base
        }
    }

    internal fun recomputeAlphaFromLux(lux: Float) {
        val raw = LightSensorMonitor.computeAlphaFromLux(lux)
        val scaled = (raw * circadianMultiplier()).toInt()
        updateAlphaFromLightSensor(scaled)
    }

    private fun circadianMultiplier(): Float {
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        return when (hour) {
            in 22..23, in 0..6 -> 1.15f
            in 7..17 -> 0.85f
            else -> 1.0f
        }
    }

    /** 深夜 / 极暗环境略偏琥珀, 白天标准羊皮纸色 */
    private fun autoBaseRgb(lux: Float): Int {
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        val deepNight = hour >= 22 || hour < 6 || (lux >= 0f && lux < 10f)
        return if (deepNight) DEEP_NIGHT_RGB else BASE_RGB
    }
}

object EyeCareLifecycleCallback : Application.ActivityLifecycleCallbacks {

    private var currentActivityRef: WeakReference<Activity>? = null
    val currentActivity: Activity?
        get() = currentActivityRef?.get()

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityPostCreated(activity: Activity, savedInstanceState: Bundle?) {
        EyeCareHelper.apply(activity)
    }
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityResumed(activity: Activity) {
        currentActivityRef = WeakReference(activity)
        EyeCareHelper.apply(activity)
    }
    override fun onActivityPaused(activity: Activity) {
        if (currentActivityRef?.get() === activity) {
            currentActivityRef = null
        }
    }
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
}

object LightSensorMonitor : SensorEventListener {

    private var sensorManager: SensorManager? = null
    private var lightSensor: Sensor? = null
    @Volatile
    private var started = false

    @Volatile
    var lastLux: Float = -1f
        internal set

    @Synchronized
    fun start() {
        if (started) return
        val sm = appCtx.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
        val sensor = sm.getDefaultSensor(Sensor.TYPE_LIGHT) ?: return
        sensorManager = sm
        lightSensor = sensor
        sm.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
        started = true
    }

    @Synchronized
    fun stop() {
        if (!started) return
        sensorManager?.unregisterListener(this)
        sensorManager = null
        lightSensor = null
        started = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_LIGHT) return
        val lux = event.values.getOrNull(0) ?: return
        lastLux = lux
        EyeCareHelper.recomputeAlphaFromLux(lux)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    internal fun computeAlphaFromLux(lux: Float): Int = when {
        lux < 10f -> 0x66
        lux < 50f -> 0x4D
        lux < 300f -> 0x40
        lux < 1000f -> 0x33
        else -> 0x26
    }
}
