package com.playtorrio.playtorrio_tv

import android.animation.ObjectAnimator
import android.content.Context
import android.util.AttributeSet
import android.util.Log
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import org.videolan.libvlc.MediaPlayer

class AudioPanel @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    private val panelRoot: View
    private val recyclerView: RecyclerView
    private val audioDelayMinus: TextView
    private val audioDelayValue: TextView
    private val audioDelayPlus: TextView
    private val audioDelayReset: TextView
    private val closeButton: TextView
    private val adapter: AudioTrackAdapter

    private var mediaPlayer: MediaPlayer? = null
    private var isVisible = false
    private var currentAudioDelay = 0L // in milliseconds

    init {
        LayoutInflater.from(context).inflate(R.layout.audio_panel, this, true)

        panelRoot = findViewById(R.id.audioPanelRoot)
        recyclerView = findViewById(R.id.audioTrackRecyclerView)
        audioDelayMinus = findViewById(R.id.audioDelayMinus)
        audioDelayValue = findViewById(R.id.audioDelayValue)
        audioDelayPlus = findViewById(R.id.audioDelayPlus)
        audioDelayReset = findViewById(R.id.audioDelayReset)
        closeButton = findViewById(R.id.audioCloseButton)

        recyclerView.layoutManager = LinearLayoutManager(context)
        adapter = AudioTrackAdapter(
            onTrackSelected = { trackId -> onAudioTrackSelected(trackId) },
            onDismiss = { dismiss() }
        )
        recyclerView.adapter = adapter

        setupDelayControls()
        setupCloseButton()
    }

    private fun setupDelayControls() {
        audioDelayMinus.setOnClickListener {
            adjustAudioDelay(-500)
        }

        audioDelayMinus.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        // Do nothing - lock focus
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        adjustAudioDelay(-500)
                        true
                    }
                    KeyEvent.KEYCODE_BACK -> {
                        dismiss()
                        true
                    }
                    else -> false
                }
            } else false
        }

        audioDelayPlus.setOnClickListener {
            adjustAudioDelay(500)
        }

        audioDelayPlus.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        // Do nothing - lock focus
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        adjustAudioDelay(500)
                        true
                    }
                    KeyEvent.KEYCODE_BACK -> {
                        dismiss()
                        true
                    }
                    else -> false
                }
            } else false
        }

        audioDelayReset.setOnClickListener {
            resetAudioDelay()
        }

        audioDelayReset.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        // Do nothing - lock focus
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        resetAudioDelay()
                        true
                    }
                    KeyEvent.KEYCODE_BACK -> {
                        dismiss()
                        true
                    }
                    else -> false
                }
            } else false
        }
    }

    private fun setupCloseButton() {
        closeButton.setOnClickListener {
            dismiss()
        }

        closeButton.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        dismiss()
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        // Do nothing - lock focus
                        true
                    }
                    else -> false
                }
            } else false
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isVisible) {
            if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                dismiss()
                return true
            }
            return super.dispatchKeyEvent(event)
        }
        return false
    }

    fun setMediaPlayer(player: MediaPlayer) {
        this.mediaPlayer = player
    }

    fun show() {
        if (isVisible) return

        val player = mediaPlayer ?: return

        // Get audio tracks from player
        val audioTracks = player.audioTracks
        if (audioTracks == null || audioTracks.isEmpty()) {
            Log.w("AudioPanel", "No audio tracks available")
            return
        }

        val currentTrack = player.audioTrack
        adapter.setTracks(audioTracks.toList(), currentTrack)

        panelRoot.visibility = View.VISIBLE
        isVisible = true

        // Slide in animation
        panelRoot.translationX = panelRoot.width.toFloat()
        ObjectAnimator.ofFloat(panelRoot, "translationX", 0f).apply {
            duration = 200
            start()
        }

        // Focus first track
        recyclerView.post {
            recyclerView.findViewHolderForAdapterPosition(0)?.itemView?.requestFocus()
        }
    }

    fun dismiss() {
        if (!isVisible) return

        isVisible = false

        // Slide out animation
        ObjectAnimator.ofFloat(panelRoot, "translationX", panelRoot.width.toFloat()).apply {
            duration = 180
            start()
        }.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) {
                panelRoot.visibility = View.GONE
                onDismissCallback?.invoke()
            }
        })
    }

    private var onDismissCallback: (() -> Unit)? = null

    fun setOnDismissListener(callback: () -> Unit) {
        onDismissCallback = callback
    }

    private fun onAudioTrackSelected(trackId: Int) {
        val player = mediaPlayer ?: return
        player.audioTrack = trackId
        Log.d("AudioPanel", "Audio track switched to: $trackId")
        
        // Update adapter
        adapter.setActiveTrack(trackId)
    }

    private fun adjustAudioDelay(deltaMs: Long) {
        val player = mediaPlayer ?: return
        currentAudioDelay += deltaMs
        
        // Convert to microseconds for LibVLC
        player.audioDelay = currentAudioDelay * 1000L
        
        audioDelayValue.text = "${currentAudioDelay} ms"
        Log.d("AudioPanel", "Audio delay adjusted to: $currentAudioDelay ms")
    }

    private fun resetAudioDelay() {
        val player = mediaPlayer ?: return
        currentAudioDelay = 0L
        player.audioDelay = 0L
        audioDelayValue.text = "0 ms"
        Log.d("AudioPanel", "Audio delay reset")
    }
}

class AudioTrackAdapter(
    private val onTrackSelected: (Int) -> Unit,
    private val onDismiss: () -> Unit
) : RecyclerView.Adapter<AudioTrackAdapter.ViewHolder>() {

    private var tracks = listOf<MediaPlayer.TrackDescription>()
    private var activeTrackId = -1

    fun setTracks(newTracks: List<MediaPlayer.TrackDescription>, activeId: Int) {
        tracks = newTracks
        activeTrackId = activeId
        notifyDataSetChanged()
    }

    fun setActiveTrack(trackId: Int) {
        activeTrackId = trackId
        notifyDataSetChanged()
    }

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val root: View = view.findViewById(R.id.audioTrackItemRoot)
        val accentBar: View = view.findViewById(R.id.audioAccentBar)
        val label: TextView = view.findViewById(R.id.audioTrackLabel)
        val info: TextView = view.findViewById(R.id.audioTrackInfo)
        val checkmark: TextView = view.findViewById(R.id.audioCheckmark)

        fun bind(track: MediaPlayer.TrackDescription) {
            label.text = track.name ?: "Track ${track.id}"
            info.text = "Track ${track.id}"
            checkmark.visibility = if (track.id == activeTrackId) View.VISIBLE else View.INVISIBLE

            root.setOnClickListener {
                onTrackSelected(track.id)
            }

            root.setOnFocusChangeListener { _, hasFocus ->
                if (hasFocus) {
                    root.scaleX = 1.05f
                    root.scaleY = 1.05f
                    root.setBackgroundColor(0xFF1A1A1A.toInt())
                    accentBar.visibility = View.VISIBLE
                } else {
                    root.scaleX = 1.0f
                    root.scaleY = 1.0f
                    root.setBackgroundColor(0x00000000)
                    accentBar.visibility = View.INVISIBLE
                }
            }

            root.setOnKeyListener { _, keyCode, event ->
                if (event.action == KeyEvent.ACTION_DOWN) {
                    when (keyCode) {
                        KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                            // Do nothing - lock focus
                            true
                        }
                        KeyEvent.KEYCODE_DPAD_DOWN -> {
                            if (adapterPosition == itemCount - 1) {
                                // Last item - do nothing
                                true
                            } else {
                                false // Allow default behavior
                            }
                        }
                        KeyEvent.KEYCODE_DPAD_UP -> {
                            if (adapterPosition == 0) {
                                // First item - do nothing
                                true
                            } else {
                                false // Allow default behavior
                            }
                        }
                        KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                            onTrackSelected(track.id)
                            true
                        }
                        KeyEvent.KEYCODE_BACK -> {
                            onDismiss()
                            true
                        }
                        else -> false
                    }
                } else false
            }
        }
    }

    override fun onCreateViewHolder(parent: android.view.ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.audio_track_item, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(tracks[position])
    }

    override fun getItemCount() = tracks.size
}
