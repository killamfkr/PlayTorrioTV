package com.playtorrio.playtorrio_tv

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONArray
import org.json.JSONObject
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

class PlayerActivity : AppCompatActivity() {
    
    companion object {
        private const val TAG = "PlayerActivity"
    }
    
    private lateinit var libVLC: LibVLC
    private lateinit var mediaPlayer: MediaPlayer
    private lateinit var videoLayout: VLCVideoLayout
    
    private lateinit var controlsOverlay: View
    private lateinit var titleText: TextView
    private lateinit var playPauseButton: ImageButton
    private lateinit var seekBar: SeekBar
    private lateinit var currentTimeText: TextView
    private lateinit var totalTimeText: TextView
    private lateinit var subtitlesButton: ImageButton
    private lateinit var audioTrackButton: ImageButton
    private lateinit var aspectRatioButton: ImageButton
    private lateinit var subtitleSettingsButton: ImageButton
    private lateinit var subtitlePanel: SubtitlePanel
    private lateinit var audioPanel: AudioPanel
    private lateinit var sourcePanel: SourcePanel
    private lateinit var settingsPanel: SettingsPanel
    private lateinit var sourceButton: ImageButton
    
    private val handler = Handler(Looper.getMainLooper())
    private var isOverlayVisible = false
    private val hideOverlayRunnable = Runnable { hideOverlay() }
    private var pendingSeekMs: Long = 0  // accumulates D-pad seek delta
    private var seekTarget: Long = -1  // VLC seek target; -1 = no pending seek

    
    private var fetchedSubtitles: List<SubtitleTrack> = emptyList()
    private var currentSubtitleId: String? = null
    private var currentAspectRatio = 0 // 0=Best fit, 1=Fill, 2=16:9, 3=4:3

    // Streaming mode data
    private var isStreaming = false
    private var sourceEntries = mutableListOf<SourceEntry>()
    private var currentSourceUrl = ""
    private var streamExtractor: StreamExtractorService? = null
    private var hasAutoPlayed = false
    private var streamingTmdbId = ""
    private var streamingImdbId = ""
    private var streamingIsMovie = true
    private var streamingSeason = 0
    private var streamingEpisode = 0

    // Streaming loading overlay views
    private lateinit var streamingLoadingOverlay: View
    private lateinit var streamingTitleText: TextView
    private lateinit var streamingStatusText: TextView

    // Buffering overlay views
    private lateinit var bufferingOverlay: View
    private var isBuffering = false

    // Continue-watching data from intent
    private var cwTmdbId = -1
    private var cwImdbId = ""
    private var cwTitle = ""
    private var cwMagnet = ""
    private var cwFileIdx = -1
    private var cwSeason = -1
    private var cwEpisode = -1
    private var cwBackdropPath = ""
    private var cwPosterPath = ""
    private var cwMediaType = "movie"
    private var cwResumePositionMs = 0L
    private var hasResumed = false

    // Next episode + skip intro (JSON from Flutter)
    private var hasNextEpisodePayload = false
    private var nextEpisodeTmdbId = 0
    private var nextEpisodeSeason = 0
    private var nextEpisodeNumber = 0
    private var nextEpisodeShowTitle = ""
    private var nextEpisodeImdb = ""
    private var nextEpisodeBackdrop = ""
    private var nextEpisodePoster = ""
    private var nextEpisodeMediaType = "tv"
    private var nextEpisodeLogo = ""
    private var nextEpisodeAuto = true
    private var nextEpisodeCountdownSec = 15
    private var skipIntroSec = 0
    private var skipIntroDone = false

    private lateinit var skipIntroChip: TextView
    private lateinit var nextEpisodeOverlay: View
    private lateinit var nextEpisodeTitleText: TextView
    private lateinit var nextEpisodeCountdownText: TextView
    private lateinit var nextEpisodePlayNowButton: android.widget.Button
    private lateinit var nextEpisodeCancelButton: android.widget.Button
    private var nextEpisodeRemainingSec = 0

    private val nextEpisodeTick = object : Runnable {
        override fun run() {
            if (nextEpisodeRemainingSec <= 0) {
                fireNextEpisodeIntent()
                return
            }
            nextEpisodeCountdownText.text = "Starting in ${nextEpisodeRemainingSec}s…"
            nextEpisodeRemainingSec--
            handler.postDelayed(this, 1000L)
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        try {
            setContentView(R.layout.activity_player)
            
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            hideSystemUI()
            
            isStreaming = intent.getBooleanExtra("isStreaming", false)

            val videoUri = intent.data
            if (videoUri == null && !isStreaming) {
                showErrorAndFinish("No video URI provided")
                return
            }
            
            initViews()
            
            val title = intent.getStringExtra("title") ?: if (videoUri != null) getFilenameFromUri(videoUri) else ""
            titleText.text = title
            
            // Get TMDB info for subtitle fetching
            val tmdbId = intent.getIntExtra("tmdbId", -1)
            val imdbId = intent.getStringExtra("imdbId") ?: ""
            val season = intent.getIntExtra("season", -1)
            val episode = intent.getIntExtra("episode", -1)

            // Continue-watching extras
            cwTmdbId = tmdbId
            cwImdbId = imdbId
            cwTitle = intent.getStringExtra("title") ?: ""
            cwMagnet = intent.getStringExtra("magnet") ?: ""
            cwFileIdx = intent.getIntExtra("fileIdx", -1)
            cwSeason = season
            cwEpisode = episode
            cwBackdropPath = intent.getStringExtra("backdropPath") ?: ""
            cwPosterPath = intent.getStringExtra("posterPath") ?: ""
            cwMediaType = intent.getStringExtra("mediaType") ?: "movie"
            cwResumePositionMs = intent.getLongExtra("resumePositionMs", 0L)

            parseNextEpisodePayload(intent.getStringExtra("nextEpisodePayload"))
            
            // Start foreground service to keep app alive during playback
            PlayerForegroundService.start(this, title)
            
            // Fetch subtitles in background if we have TMDB ID
            if (tmdbId > 0) {
                fetchSubtitles(tmdbId, imdbId, season, episode)
            }
            
            val options = ArrayList<String>().apply {
                add("--no-drop-late-frames")
                add("--no-skip-frames")
                add("--rtsp-tcp")
                add("--network-caching=3000")
                add("--file-caching=3000")
                add("--http-reconnect")
                add("--subsdec-encoding=UTF-8")
            }
            
            try {
                libVLC = VlcProvider.get(this)
            } catch (e: Exception) {
                showErrorAndFinish("Failed to initialize LibVLC: ${e.message}")
                return
            }
            
            mediaPlayer = MediaPlayer(libVLC)
            videoLayout = findViewById(R.id.videoLayout)
            
            // Set up subtitle panel
            subtitlePanel.setMediaPlayer(mediaPlayer)
            subtitlePanel.setOnDismissListener {
                playPauseButton.requestFocus()
            }
            subtitlePanel.setOnSubtitleChangedListener { trackId ->
                currentSubtitleId = trackId.takeIf { it.isNotEmpty() }
            }
            
            // Set up audio panel
            audioPanel.setMediaPlayer(mediaPlayer)
            audioPanel.setOnDismissListener {
                playPauseButton.requestFocus()
            }

            // Set up source panel (streaming mode)
            sourcePanel.setOnSourceSelectedListener { source ->
                switchToSource(source)
            }
            sourcePanel.setOnProviderExtractListener { providerKey ->
                extractSingleProvider(providerKey)
            }
            sourcePanel.setOnDismissListener {
                playPauseButton.requestFocus()
            }
            
            try {
                mediaPlayer.attachViews(videoLayout, null, true, false)
            } catch (e: Exception) {
                showErrorAndFinish("Failed to attach video view: ${e.message}")
                return
            }

            setupVlcEventListener()
            wireSkipIntroAndNextEpisodeButtons()

            if (isStreaming) {
                // Streaming mode: show loading overlay, call WebStreamr only
                streamingLoadingOverlay.visibility = View.VISIBLE
                streamingTitleText.text = title
                streamingStatusText.text = "Finding sources..."

                streamingIsMovie = cwMediaType == "movie"
                streamingTmdbId = tmdbId.toString()
                streamingImdbId = imdbId
                streamingSeason = if (season > 0) season else 0
                streamingEpisode = if (episode > 0) episode else 0

                streamExtractor = StreamExtractorService(this)

                // Build provider entries for the source panel
                sourceEntries.clear()
                for ((key, name) in streamExtractor!!.getProviderKeys()) {
                    sourceEntries.add(SourceEntry(providerKey = key, providerName = name))
                }

                // Source button always visible in streaming mode
                sourceButton.visibility = View.VISIBLE
                sourcePanel.setEntries(sourceEntries, "")

                // Only call WebStreamr on launch
                streamExtractor!!.extractWebStreamrOnly(
                    imdbId = imdbId,
                    isMovie = streamingIsMovie,
                    season = streamingSeason,
                    episode = streamingEpisode,
                    onSourceFound = { source ->
                        runOnUiThread { onWebStreamrSourceFound(source) }
                    },
                    onComplete = {
                        runOnUiThread { onWebStreamrComplete() }
                    }
                )
            } else {
                // Normal mode: play the provided URI
                val media = Media(libVLC, videoUri!!)
                media.setHWDecoderEnabled(true, false)
                mediaPlayer.media = media
                media.release()
                mediaPlayer.play()
            }
            
            setupControls()
            
        } catch (e: Exception) {
            showErrorAndFinish("Player initialization failed: ${e.message}")
        }
    }

    private fun wireSkipIntroAndNextEpisodeButtons() {
        skipIntroChip.setOnClickListener {
            if (skipIntroSec <= 0) return@setOnClickListener
            val len = mediaPlayer.length
            val target = skipIntroSec * 1000L
            if (len > 0 && target < len) {
                mediaPlayer.time = target
                seekTarget = target
            }
            skipIntroChip.visibility = View.GONE
            skipIntroDone = true
        }
        nextEpisodePlayNowButton.setOnClickListener {
            handler.removeCallbacks(nextEpisodeTick)
            fireNextEpisodeIntent()
        }
        nextEpisodeCancelButton.setOnClickListener {
            handler.removeCallbacks(nextEpisodeTick)
            nextEpisodeOverlay.visibility = View.GONE
            finish()
        }
    }

    private fun parseNextEpisodePayload(json: String?) {
        if (json.isNullOrBlank()) return
        try {
            val o = JSONObject(json)
            nextEpisodeTmdbId = o.optInt("tmdbId", 0)
            if (nextEpisodeTmdbId <= 0) return
            nextEpisodeSeason = o.optInt("season", 0)
            nextEpisodeNumber = o.optInt("episode", 0)
            nextEpisodeShowTitle = o.optString("title", "")
            nextEpisodeImdb = o.optString("imdbId", "")
            nextEpisodeBackdrop = o.optString("backdropPath", "")
            nextEpisodePoster = o.optString("posterPath", "")
            nextEpisodeMediaType = o.optString("mediaType", "tv")
            nextEpisodeLogo = o.optString("logoUrl", "")
            nextEpisodeAuto = o.optBoolean("nextEpisodeAuto", true)
            nextEpisodeCountdownSec = o.optInt("nextEpisodeCountdownSec", 15).coerceIn(0, 120)
            skipIntroSec = o.optInt("skipIntroSec", 0).coerceIn(0, 600)
            hasNextEpisodePayload = nextEpisodeSeason > 0 && nextEpisodeNumber > 0
        } catch (_: Exception) {
            hasNextEpisodePayload = false
        }
    }

    private fun maybeShowSkipIntroChip() {
        if (!hasNextEpisodePayload || skipIntroDone || skipIntroSec <= 0) return
        if (cwResumePositionMs > 15_000L) {
            skipIntroDone = true
            return
        }
        val t = mediaPlayer.time
        if (t in 0 until 120_000L) {
            skipIntroChip.visibility = View.VISIBLE
        }
    }

    private fun showNextEpisodeOverlay() {
        if (!hasNextEpisodePayload) {
            finish()
            return
        }
        stopProgressUpdate()
        nextEpisodeOverlay.visibility = View.VISIBLE
        nextEpisodeTitleText.text = "Next: S${nextEpisodeSeason}E${nextEpisodeNumber}"
        handler.removeCallbacks(nextEpisodeTick)
        if (!nextEpisodeAuto || nextEpisodeCountdownSec <= 0) {
            nextEpisodeCountdownText.text = if (nextEpisodeCountdownSec <= 0) "Press Play now to continue" else ""
            nextEpisodePlayNowButton.requestFocus()
            return
        }
        nextEpisodeRemainingSec = nextEpisodeCountdownSec
        nextEpisodeCountdownText.text = "Starting in ${nextEpisodeRemainingSec}s…"
        nextEpisodeRemainingSec--
        handler.postDelayed(nextEpisodeTick, 1000L)
        nextEpisodePlayNowButton.requestFocus()
    }

    private fun fireNextEpisodeIntent() {
        if (!hasNextEpisodePayload) {
            finish()
            return
        }
        val json = JSONObject().apply {
            put("tmdbId", nextEpisodeTmdbId)
            put("season", nextEpisodeSeason)
            put("episode", nextEpisodeNumber)
            put("title", nextEpisodeShowTitle)
            put("imdbId", nextEpisodeImdb)
            put("backdropPath", nextEpisodeBackdrop)
            put("posterPath", nextEpisodePoster)
            put("mediaType", nextEpisodeMediaType)
            put("logoUrl", nextEpisodeLogo)
        }.toString()
        val i = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("playNextEpisodeJson", json)
        }
        startActivity(i)
        finish()
    }

    private fun setupVlcEventListener() {
        mediaPlayer.setEventListener { event ->
            when (event.type) {
                MediaPlayer.Event.Opening -> {
                    runOnUiThread {
                        currentTimeText.text = "00:00"
                        totalTimeText.text = "--:--"
                    }
                }
                MediaPlayer.Event.Buffering -> {
                    val pct = event.buffering
                    runOnUiThread {
                        if (pct < 100f) {
                            showBufferingOverlay()
                        } else {
                            hideBufferingOverlay()
                        }
                        startProgressUpdate()
                    }
                }
                MediaPlayer.Event.Playing -> {
                    runOnUiThread {
                        android.util.Log.d(TAG, "VLC Playing — time=${mediaPlayer.time} len=${mediaPlayer.length}")
                        playPauseButton.setImageResource(R.drawable.ic_pause_48dp)
                        hideBufferingOverlay()
                        startProgressUpdate()
                        if (!hasResumed && cwResumePositionMs > 0 && mediaPlayer.length > 0) {
                            hasResumed = true
                            mediaPlayer.time = cwResumePositionMs
                            android.util.Log.d(TAG, "Resumed playback at ${cwResumePositionMs}ms")
                        }
                        maybeShowSkipIntroChip()
                    }
                }
                MediaPlayer.Event.Paused -> {
                    runOnUiThread {
                        android.util.Log.d(TAG, "VLC Paused — time=${mediaPlayer.time}")
                        playPauseButton.setImageResource(R.drawable.ic_play_48dp)
                        stopProgressUpdate()
                    }
                }
                MediaPlayer.Event.EncounteredError -> {
                    runOnUiThread {
                        android.util.Log.w(TAG, "VLC EncounteredError — time=${mediaPlayer.time} pos=${mediaPlayer.position} len=${mediaPlayer.length}")
                    }
                }
                MediaPlayer.Event.EndReached -> {
                    runOnUiThread {
                        val pos = mediaPlayer.position
                        android.util.Log.d(TAG, "VLC EndReached — pos=$pos time=${mediaPlayer.time} len=${mediaPlayer.length}")
                        if (pos > 0.95f || pos < 0f) {
                            saveWatchProgress()
                            if (hasNextEpisodePayload) {
                                showNextEpisodeOverlay()
                            } else {
                                finish()
                            }
                        } else {
                            android.util.Log.w(TAG, "EndReached at pos=$pos — ignoring (likely seek-related)")
                        }
                    }
                }
            }
        }
    }

    private val showBufferingRunnable = Runnable {
        if (isBuffering && streamingLoadingOverlay.visibility != View.VISIBLE) {
            bufferingOverlay.visibility = View.VISIBLE
        }
    }

    private fun showBufferingOverlay() {
        if (isBuffering) return
        isBuffering = true
        // Delay showing by 500ms to avoid flicker on quick buffering
        handler.postDelayed(showBufferingRunnable, 500)
    }

    private fun hideBufferingOverlay() {
        isBuffering = false
        handler.removeCallbacks(showBufferingRunnable)
        if (bufferingOverlay.visibility == View.VISIBLE) {
            bufferingOverlay.visibility = View.GONE
        }
    }

    /** Called on UI thread each time WebStreamr finds a source. */
    private fun onWebStreamrSourceFound(source: StreamExtractorService.StreamSource) {
        val playerSource = PlayerSource(
            url = source.url,
            provider = source.provider,
            quality = source.quality,
            headers = source.headers
        )

        // Add as a separate entry in the source panel
        val entryKey = "webstreamr_${sourceEntries.count { it.providerKey.startsWith("webstreamr") }}"
        sourceEntries.add(0, SourceEntry(
            providerKey = entryKey,
            providerName = "WebStreamr",
            source = playerSource
        ))

        android.util.Log.d(TAG, "WebStreamr source found: ${source.quality}")

        if (streamingLoadingOverlay.visibility == View.VISIBLE) {
            streamingStatusText.text = "Source found!"
        }

        // Auto-play the first source
        if (!hasAutoPlayed) {
            hasAutoPlayed = true
            playStreamingSource(playerSource)
        }

        sourcePanel.setEntries(sourceEntries, currentSourceUrl)
    }

    /** Called on UI thread when WebStreamr extraction is complete. */
    private fun onWebStreamrComplete() {
        android.util.Log.d(TAG, "WebStreamr complete. Found: ${sourceEntries.count { it.source != null }}")

        if (!hasAutoPlayed) {
            // No WebStreamr sources — hide loading overlay, player is empty but source panel available
            streamingStatusText.text = "No WebStreamr results. Try a provider →"
            handler.postDelayed({
                if (streamingLoadingOverlay.visibility == View.VISIBLE) {
                    streamingLoadingOverlay.visibility = View.GONE
                    // Show source panel automatically so user can pick a provider
                    showSourcePanel()
                }
            }, 1500)
        } else if (streamingLoadingOverlay.visibility == View.VISIBLE) {
            streamingLoadingOverlay.visibility = View.GONE
        }
    }

    /** Extract a single provider on-demand when user selects it from source panel. */
    private fun extractSingleProvider(providerKey: String) {
        val idx = sourceEntries.indexOfFirst { it.providerKey == providerKey }
        if (idx < 0) return
        val entry = sourceEntries[idx]
        if (entry.source != null) {
            // Already extracted — just switch to it
            switchToSource(entry.source!!)
            return
        }

        // Cancel any in-progress extraction first
        val loadingIdx = sourceEntries.indexOfFirst { it.isLoading }
        if (loadingIdx >= 0) {
            android.util.Log.d(TAG, "Cancelling in-progress extraction: ${sourceEntries[loadingIdx].providerName}")
            streamExtractor?.cancelActiveWebViews()
            sourceEntries[loadingIdx] = sourceEntries[loadingIdx].copy(isLoading = false)
        }

        android.util.Log.d(TAG, "Extracting provider: $providerKey (${entry.providerName})")

        // Pause playback while extracting
        if (mediaPlayer.isPlaying) {
            mediaPlayer.pause()
        }

        // Mark as loading
        sourceEntries[idx] = entry.copy(isLoading = true)
        sourcePanel.setEntries(sourceEntries, currentSourceUrl)

        streamExtractor?.extractProvider(
            providerKey = providerKey,
            tmdbId = streamingTmdbId,
            isMovie = streamingIsMovie,
            season = streamingSeason,
            episode = streamingEpisode,
            onSourceFound = { source ->
                runOnUiThread {
                    val playerSource = PlayerSource(
                        url = source.url,
                        provider = source.provider,
                        quality = source.quality,
                        headers = source.headers
                    )
                    val i = sourceEntries.indexOfFirst { it.providerKey == providerKey }
                    if (i >= 0) {
                        sourceEntries[i] = sourceEntries[i].copy(source = playerSource, isLoading = false)
                        sourcePanel.setEntries(sourceEntries, currentSourceUrl)
                    }
                    // Auto-play this source (switch to it)
                    switchToSource(playerSource)
                }
            },
            onComplete = {
                runOnUiThread {
                    val i = sourceEntries.indexOfFirst { it.providerKey == providerKey }
                    if (i >= 0 && sourceEntries[i].isLoading) {
                        // Extraction finished but no source found
                        sourceEntries[i] = sourceEntries[i].copy(isLoading = false)
                        sourcePanel.setEntries(sourceEntries, currentSourceUrl)
                        android.widget.Toast.makeText(this, "No source from ${entry.providerName}", android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
            }
        )
    }

    /** Start playing a streaming source. */
    private fun playStreamingSource(source: PlayerSource) {
        android.util.Log.d(TAG, "Auto-playing: ${source.provider} (${source.quality})")

        val media = Media(libVLC, Uri.parse(source.url))
        media.setHWDecoderEnabled(true, false)
        for ((k, v) in source.headers) {
            if (k.equals("Referer", true)) {
                media.addOption(":http-referrer=$v")
            } else {
                media.addOption(":http-header=$k: $v")
            }
        }

        mediaPlayer.media = media
        media.release()
        mediaPlayer.play()

        currentSourceUrl = source.url

        // Hide loading overlay
        streamingLoadingOverlay.visibility = View.GONE
    }
    
    private fun initViews() {
        controlsOverlay = findViewById(R.id.controlsOverlay)
        titleText = findViewById(R.id.titleText)
        playPauseButton = findViewById(R.id.playPauseButton)
        seekBar = findViewById(R.id.seekBar)
        currentTimeText = findViewById(R.id.currentTimeText)
        totalTimeText = findViewById(R.id.totalTimeText)
        subtitlesButton = findViewById(R.id.subtitlesButton)
        audioTrackButton = findViewById(R.id.audioTrackButton)
        aspectRatioButton = findViewById(R.id.aspectRatioButton)
        subtitleSettingsButton = findViewById(R.id.subtitleSettingsButton)
        subtitlePanel = findViewById(R.id.subtitlePanel)
        audioPanel = findViewById(R.id.audioPanel)
        sourcePanel = findViewById(R.id.sourcePanel)
        settingsPanel = findViewById(R.id.settingsPanel)
        sourceButton = findViewById(R.id.sourceButton)
        streamingLoadingOverlay = findViewById(R.id.streamingLoadingOverlay)
        streamingTitleText = findViewById(R.id.streamingTitleText)
        streamingStatusText = findViewById(R.id.streamingStatusText)
        bufferingOverlay = findViewById(R.id.bufferingOverlay)

        skipIntroChip = findViewById(R.id.skipIntroChip)
        skipIntroChip.visibility = View.GONE

        nextEpisodeOverlay = findViewById(R.id.nextEpisodeOverlay)
        nextEpisodeTitleText = findViewById(R.id.nextEpisodeTitleText)
        nextEpisodeCountdownText = findViewById(R.id.nextEpisodeCountdownText)
        nextEpisodePlayNowButton = findViewById(R.id.nextEpisodePlayNowButton)
        nextEpisodeCancelButton = findViewById(R.id.nextEpisodeCancelButton)
        nextEpisodeOverlay.visibility = View.GONE
        
        controlsOverlay.visibility = View.GONE
        
        // Use hardware layer on controls overlay for smoother show/hide
        controlsOverlay.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        
        // All action buttons — subtle rounded bg on focus
        val backButton = findViewById<ImageButton>(R.id.backButton)
        val bottomButtons = listOf(backButton, playPauseButton, subtitlesButton, audioTrackButton, aspectRatioButton, subtitleSettingsButton, sourceButton)
        for (btn in bottomButtons) {
            btn.setOnFocusChangeListener { v, hasFocus ->
                val ib = v as ImageButton
                if (hasFocus) {
                    ib.setColorFilter(Color.WHITE)
                    ib.background = GradientDrawable().apply {
                        setColor(0x33FFFFFF)
                        cornerRadius = 22f
                    }
                    ib.scaleX = 1.15f
                    ib.scaleY = 1.15f
                } else {
                    ib.setColorFilter(Color.parseColor("#BBBBBB"))
                    ib.background = null
                    ib.scaleX = 1.0f
                    ib.scaleY = 1.0f
                }
            }
        }
        
        // SeekBar focus highlight
        seekBar.setOnFocusChangeListener { v, hasFocus ->
            if (hasFocus) {
                v.scaleY = 1.3f
            } else {
                v.scaleY = 1.0f
            }
        }

    }
    
    private fun setupControls() {
        findViewById<ImageButton>(R.id.backButton).setOnClickListener {
            finish()
        }
        
        playPauseButton.setOnClickListener {
            togglePlayPause()
            resetOverlayTimer()
        }
        
        seekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (fromUser) {
                    // Preview time label only while dragging
                    val len = mediaPlayer.length
                    android.util.Log.d(TAG, "SeekBar drag: progress=$progress len=$len")
                    if (len > 0) {
                        currentTimeText.text = formatTime((progress / 1000f * len).toLong())
                    }
                }
            }
            
            override fun onStartTrackingTouch(seekBar: SeekBar?) {
                android.util.Log.d(TAG, "SeekBar: startTracking")
                stopProgressUpdate()
            }
            
            override fun onStopTrackingTouch(sb: SeekBar?) {
                val progress = sb?.progress ?: return
                val len = mediaPlayer.length
                val targetTime = (progress / 1000f * len).toLong()
                android.util.Log.d(TAG, "SeekBar: stopTracking progress=$progress len=$len targetTime=$targetTime currentTime=${mediaPlayer.time}")
                if (len > 0) {
                    seekTarget = targetTime
                    mediaPlayer.time = targetTime
                    android.util.Log.d(TAG, "SeekBar: seeking to $targetTime")
                } else {
                    android.util.Log.w(TAG, "SeekBar: length unknown ($len), cannot seek")
                }
                startProgressUpdate()
                resetOverlayTimer()
            }
        })
        
        subtitlesButton.setOnClickListener {
            showSubtitlePanel()
            resetOverlayTimer()
        }
        
        audioTrackButton.setOnClickListener {
            showAudioPanel()
            resetOverlayTimer()
        }
        
        aspectRatioButton.setOnClickListener {
            cycleAspectRatio()
            resetOverlayTimer()
        }
        
        subtitleSettingsButton.setOnClickListener {
            showSettingsPanel()
            resetOverlayTimer()
        }

        sourceButton.setOnClickListener {
            showSourcePanel()
            resetOverlayTimer()
        }
        
        videoLayout.setOnTouchListener { _, event ->
            if (event.action == android.view.MotionEvent.ACTION_UP) {
                toggleOverlay()
            }
            true
        }
    }
    
    private fun togglePlayPause() {
        if (mediaPlayer.isPlaying) {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }
    
    private fun toggleOverlay() {
        if (isOverlayVisible) {
            hideOverlay()
        } else {
            showOverlay()
        }
    }
    
    private fun showOverlay() {
        controlsOverlay.visibility = View.VISIBLE
        isOverlayVisible = true
        seekBar.requestFocus()
        resetOverlayTimer()
    }
    
    private fun hideOverlay() {
        controlsOverlay.visibility = View.GONE
        isOverlayVisible = false
        handler.removeCallbacks(hideOverlayRunnable)
    }
    
    private fun resetOverlayTimer() {
        handler.removeCallbacks(hideOverlayRunnable)
        handler.postDelayed(hideOverlayRunnable, 4000)
    }
    
    private fun fetchSubtitles(tmdbId: Int, imdbId: String, season: Int, episode: Int) {
        Thread {
            val allTracks = java.util.Collections.synchronizedList(mutableListOf<SubtitleTrack>())

            // === Fetch from Wyzie ===
            try {
                val wyzieKey = "wyzie-0d7ef784cd5aa6b812766fb07931accb"
                var url = "https://sub.wyzie.io/search?id=$tmdbId&key=$wyzieKey"
                if (season > 0 && episode > 0) {
                    url += "&season=$season&episode=$episode"
                }
                
                android.util.Log.d("PlayerActivity", "Fetching subtitles from Wyzie: $url")
                
                val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 10000
                connection.readTimeout = 10000
                
                if (connection.responseCode == 200) {
                    val response = connection.inputStream.bufferedReader().use { it.readText() }
                    val jsonArray = org.json.JSONArray(response)
                    val batch = mutableListOf<SubtitleTrack>()
                    
                    for (i in 0 until jsonArray.length()) {
                        val obj = jsonArray.getJSONObject(i)
                        val rawUrl = obj.getString("url")
                        val downloadUrl = if (rawUrl.contains("?")) "$rawUrl&key=$wyzieKey" else "$rawUrl?key=$wyzieKey"
                        batch.add(SubtitleTrack(
                            id = obj.getString("id"),
                            label = obj.getString("display"),
                            language = obj.getString("language"),
                            url = downloadUrl,
                            source = obj.optString("source", "Wyzie"),
                            format = obj.optString("format", "SRT").uppercase(),
                            isHearingImpaired = obj.optBoolean("isHearingImpaired", false)
                        ))
                    }
                    android.util.Log.d("PlayerActivity", "Wyzie: ${batch.size} subtitles")
                    if (batch.isNotEmpty()) {
                        allTracks.addAll(batch)
                        runOnUiThread { fetchedSubtitles = ArrayList(allTracks) }
                    }
                }
                connection.disconnect()
            } catch (e: Exception) {
                android.util.Log.e("PlayerActivity", "Wyzie error: ${e.message}", e)
            }

            // === Fetch from Levrx ===
            try {
                var url = "https://api.levrx.de/search?id=$tmdbId"
                if (season > 0 && episode > 0) {
                    url += "/$season/$episode"
                }

                android.util.Log.d("PlayerActivity", "Fetching subtitles from Levrx: $url")

                val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 10000
                connection.readTimeout = 10000

                if (connection.responseCode == 200) {
                    val response = connection.inputStream.bufferedReader().use { it.readText() }
                    val json = org.json.JSONObject(response)
                    val subtitlesArray = json.getJSONArray("subtitles")
                    val batch = mutableListOf<SubtitleTrack>()

                    for (i in 0 until subtitlesArray.length()) {
                        val catObj = subtitlesArray.getJSONObject(i)
                        val category = catObj.getString("category")
                        val urls = catObj.getJSONArray("urls")

                        for (j in 0 until urls.length()) {
                            val urlStr = urls.getString(j)
                            val filename = try {
                                java.net.URI(urlStr).path
                                    ?.substringAfterLast("/")
                                    ?.substringBeforeLast(".") ?: ""
                            } catch (e: Exception) { "" }
                            val format = try {
                                java.net.URI(urlStr).path
                                    ?.substringAfterLast(".")?.uppercase() ?: "SRT"
                            } catch (e: Exception) { "SRT" }

                            batch.add(SubtitleTrack(
                                id = "levrx_${i}_${j}",
                                label = if (filename.isNotEmpty()) filename else "$category #${j + 1}",
                                language = category,
                                url = urlStr,
                                source = "Levrx",
                                format = if (format.length <= 4) format else "SRT",
                                isHearingImpaired = false
                            ))
                        }
                    }
                    android.util.Log.d("PlayerActivity", "Levrx: ${batch.size} subtitles")
                    if (batch.isNotEmpty()) {
                        allTracks.addAll(batch)
                        runOnUiThread { fetchedSubtitles = ArrayList(allTracks) }
                    }
                }
                connection.disconnect()
            } catch (e: Exception) {
                android.util.Log.e("PlayerActivity", "Levrx error: ${e.message}", e)
            }

            // === Fetch from Stremio Addons (subtitle-capable only, in parallel) ===
            if (imdbId.startsWith("tt")) {
                val addonUrls = getStremioSubtitleAddonUrls()
                val threads = mutableListOf<Thread>()
                
                for ((addonIndex, baseUrl) in addonUrls.withIndex()) {
                    val thread = Thread {
                        try {
                            val type = if (season > 0 && episode > 0) "series" else "movie"
                            val id = if (type == "series") "$imdbId:$season:$episode" else imdbId
                            val url = "${baseUrl}subtitles/$type/$id.json"

                            android.util.Log.d("PlayerActivity", "Fetching subtitles from Stremio addon: $url")

                            val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                            connection.requestMethod = "GET"
                            connection.connectTimeout = 10000
                            connection.readTimeout = 10000

                            if (connection.responseCode == 200) {
                                val response = connection.inputStream.bufferedReader().use { it.readText() }
                                val json = org.json.JSONObject(response)
                                val subtitlesArray = json.getJSONArray("subtitles")
                                val batch = mutableListOf<SubtitleTrack>()

                                val addonName = try {
                                    java.net.URI(baseUrl).host ?: "Stremio"
                                } catch (e: Exception) { "Stremio" }

                                for (i in 0 until subtitlesArray.length()) {
                                    val obj = subtitlesArray.getJSONObject(i)
                                    val subId = obj.optString("id", "stremio_${addonIndex}_${i}")
                                    val subUrl = obj.getString("url")
                                    val title = obj.optString("title", "")
                                    val langCode = obj.optString("lang", obj.optString("lang_code", ""))

                                    batch.add(SubtitleTrack(
                                        id = "stremio_${addonIndex}_${subId.hashCode()}",
                                        label = if (title.isNotEmpty()) title else "Subtitle #${i + 1}",
                                        language = langCode,
                                        url = subUrl,
                                        source = addonName,
                                        format = "VTT",
                                        isHearingImpaired = false
                                    ))
                                }
                                android.util.Log.d("PlayerActivity", "Stremio ($addonName): ${batch.size} subtitles")
                                if (batch.isNotEmpty()) {
                                    allTracks.addAll(batch)
                                    runOnUiThread { fetchedSubtitles = ArrayList(allTracks) }
                                }
                            }
                            connection.disconnect()
                        } catch (e: Exception) {
                            android.util.Log.e("PlayerActivity", "Stremio addon error ($baseUrl): ${e.message}", e)
                        }
                    }
                    threads.add(thread)
                    thread.start()
                }
                
                // Wait for all addon threads to complete
                for (thread in threads) {
                    try { thread.join() } catch (_: InterruptedException) {}
                }
            }

            runOnUiThread {
                fetchedSubtitles = ArrayList(allTracks)
                android.util.Log.d("PlayerActivity", "Total subtitles: ${allTracks.size}")
            }
        }.start()
    }

    private fun getStremioAddonUrls(): List<String> {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.stremio_addons_json", null) ?: return emptyList()
            val jsonArray = org.json.JSONArray(raw)
            (0 until jsonArray.length()).map { jsonArray.getString(it) }
        } catch (e: Exception) {
            android.util.Log.e("PlayerActivity", "Failed to read Stremio addons: ${e.message}", e)
            emptyList()
        }
    }

    private fun getStremioSubtitleAddonUrls(): List<String> {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.stremio_subtitle_addons_json", null) ?: return emptyList()
            val jsonArray = org.json.JSONArray(raw)
            (0 until jsonArray.length()).map { jsonArray.getString(it) }
        } catch (e: Exception) {
            android.util.Log.e("PlayerActivity", "Failed to read Stremio subtitle addons: ${e.message}", e)
            emptyList()
        }
    }
    
    private fun showAudioPanel() {
        audioPanel.show()
    }
    
    private fun showSubtitlePanel() {
        if (fetchedSubtitles.isEmpty()) {
            android.widget.Toast.makeText(this, "No subtitles available", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        
        subtitlePanel.show(fetchedSubtitles, currentSubtitleId)
    }
    
    private fun showSettingsPanel() {
        settingsPanel.setMediaPlayer(mediaPlayer)
        settingsPanel.show()
    }

    private fun showSourcePanel() {
        if (!isStreaming || sourceEntries.isEmpty()) return
        sourcePanel.setEntries(sourceEntries, currentSourceUrl)
        sourcePanel.show()
    }

    private fun switchToSource(source: PlayerSource) {
        val currentPos = mediaPlayer.time
        android.util.Log.d(TAG, "Switching source to ${source.provider} (${source.quality}) pos=$currentPos")

        mediaPlayer.stop()

        val media = Media(libVLC, Uri.parse(source.url))
        media.setHWDecoderEnabled(true, false)
        for ((k, v) in source.headers) {
            media.addOption(":http-referrer=$v".takeIf { k.equals("Referer", true) } ?: ":http-header=$k: $v")
        }

        mediaPlayer.media = media
        media.release()
        mediaPlayer.play()

        // Seek back to position after a short delay for buffering
        if (currentPos > 0) {
            handler.postDelayed({
                if (mediaPlayer.length > 0) {
                    mediaPlayer.time = currentPos
                }
            }, 1000)
        }

        currentSourceUrl = source.url
        sourcePanel.setEntries(sourceEntries, currentSourceUrl)
        sourcePanel.dismiss()

        android.widget.Toast.makeText(this, "${source.provider} (${source.quality})", android.widget.Toast.LENGTH_SHORT).show()
    }
    
    private fun cycleAspectRatio() {
        currentAspectRatio = (currentAspectRatio + 1) % 4
        
        when (currentAspectRatio) {
            0 -> {
                mediaPlayer.aspectRatio = null
                android.widget.Toast.makeText(this, "Aspect: Best Fit", android.widget.Toast.LENGTH_SHORT).show()
            }
            1 -> {
                mediaPlayer.scale = 0f
                android.widget.Toast.makeText(this, "Aspect: Fill", android.widget.Toast.LENGTH_SHORT).show()
            }
            2 -> {
                mediaPlayer.aspectRatio = "16:9"
                android.widget.Toast.makeText(this, "Aspect: 16:9", android.widget.Toast.LENGTH_SHORT).show()
            }
            3 -> {
                mediaPlayer.aspectRatio = "4:3"
                android.widget.Toast.makeText(this, "Aspect: 4:3", android.widget.Toast.LENGTH_SHORT).show()
            }
        }
    }
    
    private val progressUpdateRunnable = object : Runnable {
        override fun run() {
            val currentTime = mediaPlayer.time
            val totalTime = mediaPlayer.length
            
            // Retry resume seek if Playing event missed it (HLS streams)
            if (!hasResumed && cwResumePositionMs > 0 && currentTime > 0) {
                hasResumed = true
                mediaPlayer.time = cwResumePositionMs
                android.util.Log.d(TAG, "Progress runnable: resumed at ${cwResumePositionMs}ms")
            }

            if (seekTarget >= 0) {
                // We're waiting for VLC to arrive at the seek target
                val diff = Math.abs(currentTime - seekTarget)
                if (diff < 5000) {
                    // VLC arrived — clear target, resume normal updates
                    android.util.Log.d(TAG, "Progress: VLC arrived at seek target (diff=${diff}ms)")
                    seekTarget = -1
                } else {
                    // Still waiting — show seek target on seekbar, don't snap back
                    android.util.Log.d(TAG, "Progress: waiting for VLC (target=$seekTarget current=$currentTime diff=${diff}ms)")
                    if (totalTime > 0) {
                        seekBar.progress = ((seekTarget.toFloat() / totalTime) * 1000).toInt()
                        currentTimeText.text = formatTime(seekTarget)
                        totalTimeText.text = formatTime(totalTime)
                    }
                    handler.postDelayed(this, 500)
                    return
                }
            }
            
            if (totalTime > 0) {
                val progress = ((currentTime.toFloat() / totalTime) * 1000).toInt()
                seekBar.progress = progress
                currentTimeText.text = formatTime(currentTime)
                totalTimeText.text = formatTime(totalTime)
                if (skipIntroSec > 0 && !skipIntroDone && currentTime >= skipIntroSec * 1000L) {
                    skipIntroChip.visibility = View.GONE
                    skipIntroDone = true
                }
            } else if (currentTime > 0) {
                currentTimeText.text = formatTime(currentTime)
                totalTimeText.text = "--:--"
            }
            
            handler.postDelayed(this, 500)
        }
    }
    
    private fun startProgressUpdate() {
        handler.post(progressUpdateRunnable)
    }
    
    private fun stopProgressUpdate() {
        handler.removeCallbacks(progressUpdateRunnable)
    }
    
    private fun formatTime(timeMs: Long): String {
        val totalSeconds = timeMs / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        
        return if (hours > 0) {
            String.format("%d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format("%02d:%02d", minutes, seconds)
        }
    }
    
    private fun getFilenameFromUri(uri: Uri): String {
        return uri.lastPathSegment ?: "Video"
    }
    
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        // Intercept D-pad left/right on seekbar so SeekBar doesn't consume them
        if (event.action == KeyEvent.ACTION_DOWN &&
            (keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) &&
            seekBar.hasFocus() && isOverlayVisible) {
            return onKeyDown(keyCode, event)
        }
        if (event.action == KeyEvent.ACTION_UP &&
            (keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) &&
            seekBar.hasFocus()) {
            return onKeyUp(keyCode, event)
        }
        return super.dispatchKeyEvent(event)
    }

    private fun isBottomButton(view: View?): Boolean {
        return view == playPauseButton || view == subtitlesButton || view == audioTrackButton ||
               view == aspectRatioButton || view == subtitleSettingsButton ||
               (view == sourceButton && sourceButton.visibility == View.VISIBLE)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // Streaming loading overlay — only Back allowed
        if (streamingLoadingOverlay.visibility == View.VISIBLE) {
            if (keyCode == KeyEvent.KEYCODE_BACK) {
                streamExtractor?.cancel()
                finish()
                return true
            }
            return true
        }

        if (!isOverlayVisible) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
                togglePlayPause()
                return true
            }
            if (keyCode != KeyEvent.KEYCODE_BACK) {
                showOverlay()
                return true
            }
        } else {
            resetOverlayTimer()
        }
        
        val focused = currentFocus
        
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                if (seekBar.hasFocus()) {
                    togglePlayPause()
                    true
                } else {
                    false // let buttons handle their own click
                }
            }
            
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                when {
                    // Back button → seekbar
                    focused?.id == R.id.backButton -> {
                        seekBar.requestFocus()
                        true
                    }
                    // Seekbar → play/pause (first bottom button)
                    seekBar.hasFocus() -> {
                        playPauseButton.requestFocus()
                        true
                    }
                    else -> false
                }
            }
            
            KeyEvent.KEYCODE_DPAD_UP -> {
                when {
                    // Bottom buttons → seekbar
                    isBottomButton(focused) -> {
                        seekBar.requestFocus()
                        true
                    }
                    // Seekbar → back button
                    seekBar.hasFocus() -> {
                        findViewById<ImageButton>(R.id.backButton).requestFocus()
                        true
                    }
                    else -> false
                }
            }
            
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                when {
                    seekBar.hasFocus() -> {
                        // Accumulate rewind — commit on key-up
                        pendingSeekMs -= 10000
                        val len = mediaPlayer.length
                        if (len > 0) {
                            val preview = (mediaPlayer.time + pendingSeekMs).coerceIn(0, len)
                            seekTarget = preview
                            seekBar.progress = ((preview.toFloat() / len) * 1000).toInt()
                            currentTimeText.text = formatTime(preview)
                        }
                        true
                    }
                    // Bottom buttons: left navigation
                    subtitlesButton.hasFocus() -> {
                        playPauseButton.requestFocus()
                        true
                    }
                    audioTrackButton.hasFocus() -> {
                        subtitlesButton.requestFocus()
                        true
                    }
                    aspectRatioButton.hasFocus() -> {
                        audioTrackButton.requestFocus()
                        true
                    }
                    subtitleSettingsButton.hasFocus() -> {
                        aspectRatioButton.requestFocus()
                        true
                    }
                    sourceButton.hasFocus() -> {
                        subtitleSettingsButton.requestFocus()
                        true
                    }
                    else -> false
                }
            }
            
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                when {
                    seekBar.hasFocus() -> {
                        // Accumulate forward — commit on key-up
                        pendingSeekMs += 10000
                        val len = mediaPlayer.length
                        if (len > 0) {
                            val preview = (mediaPlayer.time + pendingSeekMs).coerceIn(0, len)
                            seekTarget = preview
                            seekBar.progress = ((preview.toFloat() / len) * 1000).toInt()
                            currentTimeText.text = formatTime(preview)
                        }
                        true
                    }
                    // Bottom buttons: right navigation
                    playPauseButton.hasFocus() -> {
                        subtitlesButton.requestFocus()
                        true
                    }
                    subtitlesButton.hasFocus() -> {
                        audioTrackButton.requestFocus()
                        true
                    }
                    audioTrackButton.hasFocus() -> {
                        aspectRatioButton.requestFocus()
                        true
                    }
                    aspectRatioButton.hasFocus() -> {
                        subtitleSettingsButton.requestFocus()
                        true
                    }
                    subtitleSettingsButton.hasFocus() -> {
                        if (sourceButton.visibility == View.VISIBLE) {
                            sourceButton.requestFocus()
                        }
                        true
                    }
                    else -> false
                }
            }
            
            KeyEvent.KEYCODE_BACK -> {
                if (isOverlayVisible) {
                    hideOverlay()
                    true
                } else {
                    finish()
                    true
                }
            }
            else -> super.onKeyDown(keyCode, event)
        }
    }
    
    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if ((keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT)
            && seekBar.hasFocus() && pendingSeekMs != 0L) {
            // Commit the accumulated seek
            val len = mediaPlayer.length
            val target = if (len > 0) {
                (mediaPlayer.time + pendingSeekMs).coerceIn(0, len)
            } else {
                (mediaPlayer.time + pendingSeekMs).coerceAtLeast(0)
            }
            android.util.Log.d(TAG, "D-pad seek commit: pendingMs=$pendingSeekMs currentTime=${mediaPlayer.time} target=$target len=$len")
            pendingSeekMs = 0
            seekTarget = target
            mediaPlayer.time = target
            return true
        }
        return super.onKeyUp(keyCode, event)
    }
    
    private fun showErrorAndFinish(message: String) {
        android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show()
        android.util.Log.e(TAG, message)
        finish()
    }
    
    
    private fun hideSystemUI() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_FULLSCREEN
        )
    }
    
    override fun onPause() {
        super.onPause()
        saveWatchProgress()
        mediaPlayer.pause()
    }

    private fun saveWatchProgress() {
        if (cwTmdbId <= 0 || (cwMagnet.isEmpty() && !isStreaming)) return
        val posMs = mediaPlayer.time
        var durMs = mediaPlayer.length
        // For HLS/streaming sources, length may be unknown (-1 or 0)
        // Use a large fallback so progress is close to 0 and entry is saved
        if (durMs <= 0 && isStreaming && posMs > 0) durMs = posMs * 10
        if (posMs < 0 || durMs <= 0) return

        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.continue_watching", null)
        val arr = if (raw != null) {
            try { JSONArray(raw) } catch (_: Exception) { JSONArray() }
        } else JSONArray()

        val entryKey = if (cwSeason > 0 && cwEpisode > 0) "${cwTmdbId}_s${cwSeason}e${cwEpisode}" else cwTmdbId.toString()

        // Build entry JSON
        val entry = JSONObject().apply {
            put("tmdbId", cwTmdbId)
            put("imdbId", cwImdbId)
            put("title", cwTitle)
            put("magnet", if (isStreaming) "__streaming__" else cwMagnet)
            put("fileIdx", cwFileIdx)
            put("positionMs", posMs)
            put("durationMs", durMs)
            put("season", if (cwSeason > 0) cwSeason else JSONObject.NULL)
            put("episode", if (cwEpisode > 0) cwEpisode else JSONObject.NULL)
            put("backdropPath", cwBackdropPath.ifEmpty { JSONObject.NULL })
            put("posterPath", cwPosterPath.ifEmpty { JSONObject.NULL })
            put("mediaType", cwMediaType)
            put("updatedAt", System.currentTimeMillis())
        }

        val progress = if (durMs > 0) posMs.toDouble() / durMs else 0.0

        // Remove existing entry with same key
        val newArr = JSONArray()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val objKey = buildEntryKey(obj)
            if (objKey != entryKey) newArr.put(obj)
        }

        // If nearly finished (>93%), just remove — don't re-add
        if (progress <= 0.93 && posMs >= 30000) {
            // Insert at front
            val finalArr = JSONArray()
            finalArr.put(entry)
            for (i in 0 until newArr.length().coerceAtMost(29)) {
                finalArr.put(newArr.getJSONObject(i))
            }
            val json = finalArr.toString()
            prefs.edit()
                .putString("flutter.continue_watching", json)
                .putString("flutter.continue_watching_json", json)
                .apply()
        } else if (progress > 0.93) {
            // Finished — save the cleaned list (entry removed)
            val json = newArr.toString()
            prefs.edit()
                .putString("flutter.continue_watching", json)
                .putString("flutter.continue_watching_json", json)
                .apply()
        }
        // If < 30s watched, don't save at all
    }

    private fun buildEntryKey(obj: JSONObject): String {
        val id = obj.optInt("tmdbId", -1).toString()
        val s = obj.opt("season")
        val e = obj.opt("episode")
        return if (s is Int && e is Int) "${id}_s${s}e${e}" else id
    }
    
    override fun onStop() {
        super.onStop()
        saveWatchProgress()
        mediaPlayer.stop()
        mediaPlayer.detachViews()
    }
    
    override fun onDestroy() {
        handler.removeCallbacks(nextEpisodeTick)
        super.onDestroy()
        
        // Cancel streaming extraction if running
        streamExtractor?.cancel()
        streamExtractor = null

        // Stop foreground service
        PlayerForegroundService.stop(this)
        
        handler.removeCallbacksAndMessages(null)
        mediaPlayer.release()
        // libVLC is managed by VlcProvider singleton — don't release here
    }
}
