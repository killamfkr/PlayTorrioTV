package com.playtorrio.playtorrio_tv

import android.animation.ObjectAnimator
import android.content.Context
import android.util.AttributeSet
import android.util.Log
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.videolan.libvlc.MediaPlayer

class SettingsPanel @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    private val panelRoot: View
    private val delayRow: LinearLayout
    private val delayValue: TextView
    private val closeButton: TextView

    private var mediaPlayer: MediaPlayer? = null
    private var isVisible = false
    private var onDismissCallback: (() -> Unit)? = null

    // Current delay in 100ms steps
    private var delayMs = 0L

    init {
        LayoutInflater.from(context).inflate(R.layout.settings_panel, this, true)

        panelRoot = findViewById(R.id.settingsPanelRoot)
        delayRow = findViewById(R.id.delayRow)
        delayValue = findViewById(R.id.delayValue)
        closeButton = findViewById(R.id.settingsCloseButton)

        // Hide unused rows
        findViewById<View>(R.id.sizeRow).visibility = View.GONE
        findViewById<View>(R.id.positionRow).visibility = View.GONE

        setupDelayRow()
        setupCloseButton()
    }

    private fun setupDelayRow() {
        delayRow.isFocusable = true
        delayRow.isFocusableInTouchMode = true

        delayRow.setOnFocusChangeListener { _, hasFocus ->
            delayRow.setBackgroundColor(if (hasFocus) 0xFF1A1A1A.toInt() else 0x00000000)
        }

        delayRow.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_RIGHT -> { adjustDelay(100); true }
                    KeyEvent.KEYCODE_DPAD_LEFT -> { adjustDelay(-100); true }
                    KeyEvent.KEYCODE_DPAD_DOWN -> { closeButton.requestFocus(); true }
                    KeyEvent.KEYCODE_DPAD_UP -> true // lock
                    KeyEvent.KEYCODE_BACK -> { dismiss(); true }
                    else -> false
                }
            } else false
        }
    }

    private fun setupCloseButton() {
        closeButton.setOnClickListener { dismiss() }
        closeButton.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> { dismiss(); true }
                    KeyEvent.KEYCODE_DPAD_UP -> { delayRow.requestFocus(); true }
                    KeyEvent.KEYCODE_DPAD_DOWN -> true // lock
                    else -> false
                }
            } else false
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isVisible && event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
            dismiss(); return true
        }
        return if (isVisible) super.dispatchKeyEvent(event) else false
    }

    fun setMediaPlayer(player: MediaPlayer) {
        this.mediaPlayer = player
        // Sync current delay from player
        delayMs = player.spuDelay / 1000 // spuDelay is in microseconds
        updateUI()
    }

    fun show() {
        if (isVisible) return
        // Sync from player
        mediaPlayer?.let { delayMs = it.spuDelay / 1000 }
        updateUI()

        panelRoot.visibility = View.VISIBLE
        isVisible = true
        panelRoot.translationX = panelRoot.width.toFloat()
        ObjectAnimator.ofFloat(panelRoot, "translationX", 0f).apply {
            duration = 200; start()
        }
        delayRow.post { delayRow.requestFocus() }
    }

    fun dismiss() {
        if (!isVisible) return
        isVisible = false
        ObjectAnimator.ofFloat(panelRoot, "translationX", panelRoot.width.toFloat()).apply {
            duration = 180; start()
        }.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) {
                panelRoot.visibility = View.GONE
                onDismissCallback?.invoke()
            }
        })
    }

    fun setOnDismissListener(callback: () -> Unit) {
        onDismissCallback = callback
    }

    private fun adjustDelay(deltaMs: Long) {
        delayMs += deltaMs
        delayMs = delayMs.coerceIn(-10000, 10000)
        // libVLC spuDelay is in microseconds
        mediaPlayer?.spuDelay = delayMs * 1000
        updateUI()
        Log.d("SettingsPanel", "Subtitle delay: ${delayMs}ms (spuDelay=${delayMs * 1000}us)")
    }

    private fun updateUI() {
        val seconds = delayMs / 1000f
        val sign = if (delayMs > 0) "+" else ""
        delayValue.text = String.format("%s%.1fs", sign, seconds)
    }
}
