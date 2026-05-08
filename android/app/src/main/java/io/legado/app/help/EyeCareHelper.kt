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
import io.legado.app.utils.getPrefBoolean
import splitties.init.appCtx
import java.lang.ref.WeakReference
import kotlin.math.abs

/**
 * 万象书屋 D-18~D-20: 护眼模式 — 全屏暖色滤镜 + 环境光自适应.
 *
 * D-18 v1: 单 alpha (12% / 24% / 40%) — 颜色 #FFE4B5 / #FFD480, 视觉强烈
 * D-19 v2: alpha 30% + #FAF0DC 浅羊皮纸 — 跟番茄/微信读书对齐, 自然柔和
 * D-20 v3: 接入环境光传感器 (TYPE_LIGHT) 动态调整 alpha — 借鉴 Pixel 10 Comfort View 思路
 *
 * 自适应映射 (lux → alpha):
 *   <10 lux  (深夜暗室): 40% — 屏幕过亮反差大, 加强滤镜
 *   10-50    (昏暗):     30% — 行业标准基线
 *   50-300   (普通室内): 25% — 常规阅读
 *   300-1000 (明亮):     20% — 减弱避免发灰
 *   >1000    (强光/户外): 15% — 几乎不影响可读性
 *
 * 节流: 只有 alpha 跨档 (差 >= 0x10) 才重 apply, 避免传感器抖动导致 overlay 频繁刷新.
 *
 * 不需 SYSTEM_ALERT_WINDOW 权限 (它只在本 Activity content view 内有效).
 */
object EyeCareHelper {

    private const val OVERLAY_TAG = "wanxiang_eye_care_overlay"
    private const val LOG_TAG = "EyeCareHelper"

    /** 业界主流护眼黄白色 #FAF0DC (静读天下夜间环境推荐 + 番茄小说"羊皮纸"对齐) */
    private const val BASE_RGB = 0xFAF0DC

    /**
     * D-20: 默认 alpha 30% (无传感器时 fallback). 跟 D-19 完全等价.
     * 有传感器时, currentAlpha 会被 LightSensorMonitor 实时更新.
     */
    private const val DEFAULT_ALPHA = 0x4D
    @Volatile
    private var currentAlpha: Int = DEFAULT_ALPHA

    /** 当前 overlay 颜色 = currentAlpha << 24 | BASE_RGB */
    private val overlayColor: Int
        get() = (currentAlpha shl 24) or BASE_RGB

    fun isEnabled(): Boolean {
        return appCtx.getPrefBoolean(PreferKey.eyeCareMode, false)
    }

    /**
     * D-20: 由 LightSensorMonitor 在环境光变化时调用, 通知 overlay 用新 alpha 重绘.
     * 如果 newAlpha 跟 currentAlpha 差异小于 0x10 (4%), 节流不更新 (防 overlay 闪烁).
     */
    internal fun updateAlphaFromLightSensor(newAlpha: Int) {
        if (abs(newAlpha - currentAlpha) < 0x10) return
        currentAlpha = newAlpha.coerceIn(0x20, 0x80)  // [12.5%, 50%] 安全区间
        // 通知当前 top activity 重绘 overlay
        EyeCareLifecycleCallback.currentActivity?.let { apply(it) }
        io.legado.app.utils.LogUtils.d(
            LOG_TAG,
            "alpha auto-adjusted to ${currentAlpha} (color=#${overlayColor.toUInt().toString(16)})"
        )
    }

    /**
     * 在 [activity] 的 content view 顶层挂一个全屏暖色滤镜 View.
     * 重复调用幂等: 已有 overlay 时刷新颜色 (alpha 可能因环境光变化), 不重复 addView.
     */
    fun apply(activity: Activity) {
        val enabled = isEnabled()
        // 万象书屋: addView 必须用 android.R.id.content 而不是 decorView
        val root = activity.findViewById<ViewGroup>(android.R.id.content) ?: run {
            io.legado.app.utils.LogUtils.d(LOG_TAG, "apply: content view null, skip")
            return
        }
        val existing = root.findViewWithTag<View>(OVERLAY_TAG)
        if (enabled) {
            if (existing == null) {
                val overlay = View(activity).apply {
                    tag = OVERLAY_TAG
                    setBackgroundColor(overlayColor)
                    isClickable = false
                    isFocusable = false
                    layoutParams = android.widget.FrameLayout.LayoutParams(
                        android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                        android.widget.FrameLayout.LayoutParams.MATCH_PARENT
                    )
                }
                root.addView(overlay)
                overlay.bringToFront()
                io.legado.app.utils.LogUtils.d(
                    LOG_TAG,
                    "overlay added (alpha=#${currentAlpha.toString(16)})"
                )
            } else {
                // D-20: 已存在 overlay 时刷新颜色 (alpha 可能因环境光变化)
                existing.setBackgroundColor(overlayColor)
                existing.visibility = View.VISIBLE
                existing.bringToFront()
            }
            // 启动光线传感器 (幂等), 自适应 alpha
            LightSensorMonitor.start()
        } else {
            existing?.let {
                root.removeView(it)
                io.legado.app.utils.LogUtils.d(LOG_TAG, "overlay removed")
            }
            // 关闭护眼时停止传感器, 节电
            LightSensorMonitor.stop()
        }
    }

    @Suppress("unused")
    fun remove(activity: Activity) {
        val root = activity.window?.decorView as? ViewGroup ?: return
        root.findViewWithTag<View>(OVERLAY_TAG)?.let { root.removeView(it) }
    }
}

/**
 * 万象书屋 D-19/D-20: ApplicationLifecycleCallbacks — 给所有 Activity 自动注入护眼滤镜
 * + 维护 currentActivity 弱引用让 LightSensorMonitor 知道往哪个 Activity 应用变化.
 *
 * onActivityPostCreated 在 setContentView 之后被调, R.id.content 已 attach, addView 安全.
 * onActivityResumed 兜底 (用户切到后台再回前台 / 或运行时切换护眼开关).
 */
object EyeCareLifecycleCallback : Application.ActivityLifecycleCallbacks {

    /** D-20: 当前 resumed activity 的弱引用, 给传感器变化时回调用 */
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

/**
 * 万象书屋 D-20: 环境光传感器监听器 — 借鉴 Pixel 10 Comfort View 自适应思路.
 *
 * Android TYPE_LIGHT 是低功耗硬件传感器, 持续监听基本不耗电 (mW 级).
 * 没有传感器的设备 (老机型 / VM): getDefaultSensor 返 null, start() 直接返回, fallback 走默认 alpha.
 *
 * 节流策略:
 *   - SensorManager.SENSOR_DELAY_UI (~60ms 一次回调) 已经够慢, 不需额外节流
 *   - alpha 跨档 (差 >= 0x10) 才通知 EyeCareHelper 更新 overlay, 避免视觉闪烁
 *
 * 生命周期: 跟随 EyeCareHelper.apply(enabled=true) 启动 / apply(enabled=false) 停止.
 */
object LightSensorMonitor : SensorEventListener {

    private const val LOG_TAG = "LightSensorMonitor"

    private var sensorManager: SensorManager? = null
    private var lightSensor: Sensor? = null
    @Volatile
    private var started = false

    /** 上次采样的 lux, 调试用 */
    @Volatile
    var lastLux: Float = -1f
        private set

    @Synchronized
    fun start() {
        if (started) return
        val sm = appCtx.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            ?: run {
                io.legado.app.utils.LogUtils.d(LOG_TAG, "no SensorManager, skip")
                return
            }
        val sensor = sm.getDefaultSensor(Sensor.TYPE_LIGHT)
        if (sensor == null) {
            io.legado.app.utils.LogUtils.d(LOG_TAG, "no TYPE_LIGHT sensor, fallback to default alpha")
            return
        }
        sensorManager = sm
        lightSensor = sensor
        sm.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
        started = true
        io.legado.app.utils.LogUtils.d(
            LOG_TAG,
            "started, sensor=${sensor.name} maxRange=${sensor.maximumRange} resolution=${sensor.resolution}"
        )
    }

    @Synchronized
    fun stop() {
        if (!started) return
        sensorManager?.unregisterListener(this)
        sensorManager = null
        lightSensor = null
        started = false
        io.legado.app.utils.LogUtils.d(LOG_TAG, "stopped")
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_LIGHT) return
        val lux = event.values.getOrNull(0) ?: return
        lastLux = lux
        val newAlpha = computeAlphaFromLux(lux)
        EyeCareHelper.updateAlphaFromLightSensor(newAlpha)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    /**
     * lux → alpha 映射函数 (业界推荐参考静读天下分级 + 番茄小说阅读器实测):
     *   <10    深夜暗室:  alpha 0x66 (40%) — 屏幕过亮反差大, 加强滤镜
     *   10~50  昏暗:      alpha 0x4D (30%) — 行业标准基线
     *   50~300 普通室内:  alpha 0x40 (25%) — 常规阅读
     *   300~1000 明亮:    alpha 0x33 (20%) — 减弱避免画面发灰
     *   >1000  强光/户外: alpha 0x26 (15%) — 几乎不影响可读性
     */
    internal fun computeAlphaFromLux(lux: Float): Int = when {
        lux < 10f   -> 0x66
        lux < 50f   -> 0x4D
        lux < 300f  -> 0x40
        lux < 1000f -> 0x33
        else        -> 0x26
    }
}
