package com.playtorrio.playtorrio_tv

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import kotlinx.coroutines.*
import java.net.URL
import java.util.regex.Pattern

data class SubtitleEntry(
    val startTime: Long,  // milliseconds
    val endTime: Long,    // milliseconds
    val text: String
)

class SubtitleRenderer @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    private val subtitleTextView: TextView
    private val handler = Handler(Looper.getMainLooper())
    private var subtitles = listOf<SubtitleEntry>()
    private var currentIndex = 0
    private var isPlaying = false
    private var startTimeMs = 0L
    
    // Customization settings
    var subtitleSize = 100 // percentage
        set(value) {
            field = value
            updateTextSize()
        }
    
    var subtitlePosition = 0 // 0=Bottom, 1=Middle, 2=Top
        set(value) {
            field = value
            updatePosition()
        }
    
    var subtitleDelay = 0L // milliseconds
    
    init {
        subtitleTextView = TextView(context).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setShadowLayer(8f, 0f, 0f, Color.BLACK) // Strong shadow for readability
            setTypeface(null, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(32, 16, 32, 16)
            setBackgroundColor(Color.TRANSPARENT) // NO BACKGROUND
            
            // Make completely non-interactive
            isFocusable = false
            isFocusableInTouchMode = false
            isClickable = false
            isLongClickable = false
        }
        
        addView(subtitleTextView, LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            bottomMargin = 80
        })
        
        subtitleTextView.visibility = GONE
        
        // Make the entire renderer non-interactive
        isFocusable = false
        isFocusableInTouchMode = false
        isClickable = false
    }
    
    fun loadSubtitleFromUrl(url: String) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                Log.d("SubtitleRenderer", "Loading subtitle from: $url")
                val content = URL(url).readText()
                val parsed = parseSRT(content)
                
                withContext(Dispatchers.Main) {
                    subtitles = parsed
                    currentIndex = 0
                    Log.d("SubtitleRenderer", "Loaded ${subtitles.size} subtitle entries")
                }
            } catch (e: Exception) {
                Log.e("SubtitleRenderer", "Failed to load subtitle: ${e.message}", e)
            }
        }
    }
    
    fun start(currentPositionMs: Long) {
        isPlaying = true
        startTimeMs = System.currentTimeMillis() - currentPositionMs
        updateSubtitle()
    }
    
    fun pause() {
        isPlaying = false
        handler.removeCallbacks(updateRunnable)
    }
    
    fun stop() {
        isPlaying = false
        handler.removeCallbacks(updateRunnable)
        subtitleTextView.visibility = GONE
        subtitles = emptyList()
        currentIndex = 0
    }
    
    fun seek(positionMs: Long) {
        startTimeMs = System.currentTimeMillis() - positionMs
        currentIndex = 0
        if (isPlaying) {
            updateSubtitle()
        }
    }
    
    private val updateRunnable = object : Runnable {
        override fun run() {
            if (isPlaying) {
                updateSubtitle()
                handler.postDelayed(this, 250) // Update every 250ms (reduced from 100ms to prevent lag)
            }
        }
    }
    
    private fun updateSubtitle() {
        if (subtitles.isEmpty()) return
        
        val currentTime = System.currentTimeMillis() - startTimeMs + subtitleDelay
        
        // Find the subtitle that should be displayed
        var foundSubtitle: SubtitleEntry? = null
        
        for (i in currentIndex until subtitles.size) {
            val sub = subtitles[i]
            if (currentTime >= sub.startTime && currentTime <= sub.endTime) {
                foundSubtitle = sub
                currentIndex = i
                break
            } else if (currentTime < sub.startTime) {
                break
            }
        }
        
        // Also check backwards in case we seeked
        if (foundSubtitle == null && currentIndex > 0) {
            for (i in currentIndex - 1 downTo 0) {
                val sub = subtitles[i]
                if (currentTime >= sub.startTime && currentTime <= sub.endTime) {
                    foundSubtitle = sub
                    currentIndex = i
                    break
                } else if (currentTime > sub.endTime) {
                    break
                }
            }
        }
        
        if (foundSubtitle != null) {
            if (subtitleTextView.text != foundSubtitle.text) {
                subtitleTextView.text = foundSubtitle.text
                subtitleTextView.visibility = VISIBLE
            }
        } else {
            if (subtitleTextView.visibility == VISIBLE) {
                subtitleTextView.visibility = GONE
            }
        }
        
        if (isPlaying) {
            handler.postDelayed(updateRunnable, 250)
        }
    }
    
    private fun updateTextSize() {
        val baseSize = 20f
        val scaledSize = baseSize * (subtitleSize / 100f)
        subtitleTextView.setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledSize)
    }
    
    private fun updatePosition() {
        val params = subtitleTextView.layoutParams as LayoutParams
        
        when (subtitlePosition) {
            0 -> { // Bottom
                params.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                params.bottomMargin = 80
                params.topMargin = 0
            }
            1 -> { // Middle
                params.gravity = Gravity.CENTER
                params.bottomMargin = 0
                params.topMargin = 0
            }
            2 -> { // Top
                params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                params.topMargin = 80
                params.bottomMargin = 0
            }
        }
        
        subtitleTextView.layoutParams = params
    }
    
    private fun parseSRT(content: String): List<SubtitleEntry> {
        val entries = mutableListOf<SubtitleEntry>()
        val blocks = content.trim().split("\n\n")
        
        for (block in blocks) {
            try {
                val lines = block.trim().split("\n")
                if (lines.size < 3) continue
                
                // Line 0: index (ignore)
                // Line 1: timestamp
                // Line 2+: text
                
                val timePattern = Pattern.compile("(\\d{2}):(\\d{2}):(\\d{2}),(\\d{3})\\s*-->\\s*(\\d{2}):(\\d{2}):(\\d{2}),(\\d{3})")
                val matcher = timePattern.matcher(lines[1])
                
                if (matcher.find()) {
                    val startTime = parseTime(
                        matcher.group(1)!!.toInt(),
                        matcher.group(2)!!.toInt(),
                        matcher.group(3)!!.toInt(),
                        matcher.group(4)!!.toInt()
                    )
                    
                    val endTime = parseTime(
                        matcher.group(5)!!.toInt(),
                        matcher.group(6)!!.toInt(),
                        matcher.group(7)!!.toInt(),
                        matcher.group(8)!!.toInt()
                    )
                    
                    val text = lines.drop(2).joinToString("\n")
                    
                    entries.add(SubtitleEntry(startTime, endTime, text))
                }
            } catch (e: Exception) {
                Log.w("SubtitleRenderer", "Failed to parse subtitle block: ${e.message}")
            }
        }
        
        return entries
    }
    
    private fun parseTime(hours: Int, minutes: Int, seconds: Int, millis: Int): Long {
        return (hours * 3600000L) + (minutes * 60000L) + (seconds * 1000L) + millis
    }
}
