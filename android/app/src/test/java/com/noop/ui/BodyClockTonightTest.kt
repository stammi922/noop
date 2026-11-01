package com.noop.ui

import com.noop.analytics.CircadianEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The Body clock card's Tonight line waits for the personal sleep need.
 *
 * `SleepScreen` passes `needHours = null` until the full-history model (and with it the sleep-debt ledger)
 * has built. The card must then print no line at all: an 8 h fallback would show a 9 h-need user a
 * fall-asleep time an hour too late until the model loaded. iOS never had the fallback.
 */
class BodyClockTonightTest {

    private val solid = CircadianEngine.PhaseEstimate(
        tempMinHour = 4.5, acrophaseHours = 16.5, offsetVsScheduleMinutes = 0.0,
        confidence = CircadianEngine.PhaseConfidence.SOLID, note = "",
    )

    @Test
    fun noLineWhileNeedIsLoading() {
        assertNull(tonightFor(solid, needHours = null))
    }

    @Test
    fun lineUsesThePersonalNeedOnceLoaded() {
        val t = tonightFor(solid, needHours = 9.0)!!
        assertEquals("07:00", CircadianEngine.clockToFiveMinutes(t.wakeHour))
        assertEquals("22:00", CircadianEngine.clockToFiveMinutes(t.fallAsleepHour))
    }
}
