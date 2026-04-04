package com.playtorrio.playtorrio_tv

import android.content.Context
import android.util.Log
import org.videolan.libvlc.LibVLC
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Singleton that pre-loads LibVLC on a background thread so
 * PlayerActivity doesn't pay the cold-start cost.
 */
object VlcProvider {
    private const val TAG = "VlcProvider"

    @Volatile
    private var instance: LibVLC? = null
    private val warming = AtomicBoolean(false)
    private var ready = CountDownLatch(1)
    private var currentFontSize: Int = -1 // track which fontsize was used

    private val defaultOptions = arrayListOf(
        "--no-drop-late-frames",
        "--no-skip-frames",
        "--rtsp-tcp",
        "--network-caching=3000",
        "--file-caching=3000",
        "--http-reconnect",
        "--subsdec-encoding=UTF-8"
    )

    private fun buildOptions(context: Context): ArrayList<String> {
        val prefs = context.applicationContext
            .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val fontSize = try {
            (prefs.all["flutter.subtitle_fontsize"] as? Number)?.toInt() ?: 0
        } catch (_: Exception) { 0 }
        currentFontSize = fontSize
        val opts = ArrayList(defaultOptions)
        if (fontSize > 0) {
            opts.add("--freetype-rel-fontsize=$fontSize")
        }
        return opts
    }

    /** Start loading LibVLC in background. Safe to call multiple times. */
    fun warmup(context: Context) {
        if (instance != null || !warming.compareAndSet(false, true)) return
        val ctx = context.applicationContext
        Thread {
            try {
                val start = System.currentTimeMillis()
                instance = LibVLC(ctx, buildOptions(ctx))
                val elapsed = System.currentTimeMillis() - start
                Log.i(TAG, "LibVLC pre-loaded in ${elapsed}ms (fontsize=$currentFontSize)")
            } catch (e: Exception) {
                Log.e(TAG, "LibVLC warmup failed: ${e.message}")
                warming.set(false)
            } finally {
                ready.countDown()
            }
        }.start()
    }

    /**
     * Get the pre-loaded LibVLC instance, waiting up to [timeoutMs] if warmup
     * is still in progress. Falls back to creating a fresh instance on the
     * calling thread if warmup failed or timed out.
     * Recreates if subtitle fontsize setting changed since last creation.
     */
    fun get(context: Context, timeoutMs: Long = 5000): LibVLC {
        val prefs = context.applicationContext
            .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val fontSize = try {
            (prefs.all["flutter.subtitle_fontsize"] as? Number)?.toInt() ?: 0
        } catch (_: Exception) { 0 }

        // If fontsize changed, release old instance so we create a new one
        if (instance != null && fontSize != currentFontSize) {
            Log.i(TAG, "Subtitle fontsize changed ($currentFontSize -> $fontSize), recreating LibVLC")
            instance?.release()
            instance = null
            warming.set(false)
            ready = CountDownLatch(1)
            ready.countDown()
        }

        instance?.let { return it }
        // Warmup may still be running — wait for it
        ready.await(timeoutMs, TimeUnit.MILLISECONDS)
        instance?.let { return it }
        // Fallback: create on calling thread (same as before)
        Log.w(TAG, "Warmup unavailable, creating LibVLC on main thread")
        val vlc = LibVLC(context.applicationContext, buildOptions(context))
        instance = vlc
        return vlc
    }

    /** Release the instance (e.g. when app is destroyed). */
    fun release() {
        instance?.release()
        instance = null
        warming.set(false)
        currentFontSize = -1
    }
}
