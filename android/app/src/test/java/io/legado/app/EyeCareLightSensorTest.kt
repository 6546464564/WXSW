package io.legado.app

import io.legado.app.help.LightSensorMonitor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 万象书屋 D-20: 验证环境光传感器 lux → alpha 自适应映射.
 *
 * 边界点 (5 个档位 4 个边界):
 *   <10 → 0x66
 *   10-50 → 0x4D
 *   50-300 → 0x40
 *   300-1000 → 0x33
 *   >=1000 → 0x26
 *
 * 关键单调性: lux 越大 alpha 越小 (越亮越不需要强滤镜).
 */
class EyeCareLightSensorTest {

    @Test
    fun computeAlphaFromLux_dimDarkRoom_returnsHighAlpha() {
        // 深夜暗室 < 10 lux → alpha 40%
        assertEquals(0x66, LightSensorMonitor.computeAlphaFromLux(0f))
        assertEquals(0x66, LightSensorMonitor.computeAlphaFromLux(5f))
        assertEquals(0x66, LightSensorMonitor.computeAlphaFromLux(9.9f))
    }

    @Test
    fun computeAlphaFromLux_dim_returnsBaselineAlpha() {
        // 昏暗 10-50 lux → alpha 30% (业界基线)
        assertEquals(0x4D, LightSensorMonitor.computeAlphaFromLux(10f))
        assertEquals(0x4D, LightSensorMonitor.computeAlphaFromLux(30f))
        assertEquals(0x4D, LightSensorMonitor.computeAlphaFromLux(49.9f))
    }

    @Test
    fun computeAlphaFromLux_normalIndoor_returnsMediumAlpha() {
        // 普通室内 50-300 lux → alpha 25%
        assertEquals(0x40, LightSensorMonitor.computeAlphaFromLux(50f))
        assertEquals(0x40, LightSensorMonitor.computeAlphaFromLux(150f))
        assertEquals(0x40, LightSensorMonitor.computeAlphaFromLux(299.9f))
    }

    @Test
    fun computeAlphaFromLux_bright_returnsLowAlpha() {
        // 明亮 300-1000 lux → alpha 20%
        assertEquals(0x33, LightSensorMonitor.computeAlphaFromLux(300f))
        assertEquals(0x33, LightSensorMonitor.computeAlphaFromLux(500f))
        assertEquals(0x33, LightSensorMonitor.computeAlphaFromLux(999.9f))
    }

    @Test
    fun computeAlphaFromLux_outdoor_returnsMinimalAlpha() {
        // 强光/户外 >=1000 lux → alpha 15%
        assertEquals(0x26, LightSensorMonitor.computeAlphaFromLux(1000f))
        assertEquals(0x26, LightSensorMonitor.computeAlphaFromLux(5000f))
        assertEquals(0x26, LightSensorMonitor.computeAlphaFromLux(40000f))  // 直射阳光
    }

    @Test
    fun computeAlphaFromLux_monotonicallyDecreasing() {
        // 单调性: lux 越大 alpha 越小 (越亮屏幕越无需暖色滤镜)
        val luxes = floatArrayOf(0f, 5f, 20f, 80f, 250f, 600f, 2000f, 10000f)
        var prevAlpha = Int.MAX_VALUE
        for (lux in luxes) {
            val alpha = LightSensorMonitor.computeAlphaFromLux(lux)
            assertTrue(
                "alpha must be non-increasing as lux increases: lux=$lux alpha=$alpha prevAlpha=$prevAlpha",
                alpha <= prevAlpha
            )
            prevAlpha = alpha
        }
    }

    @Test
    fun computeAlphaFromLux_alphaInSafeRange() {
        // 万象书屋: alpha 必须落在 [0x20, 0x80] (12.5%~50%) 安全区间, 防止过淡看不出 / 过暗影响阅读
        val testLuxes = floatArrayOf(0f, 5f, 25f, 100f, 500f, 1500f, 50000f)
        for (lux in testLuxes) {
            val alpha = LightSensorMonitor.computeAlphaFromLux(lux)
            assertTrue("alpha=$alpha < 0x20 (12.5%) at lux=$lux", alpha >= 0x20)
            assertTrue("alpha=$alpha > 0x80 (50%) at lux=$lux", alpha <= 0x80)
        }
    }
}
