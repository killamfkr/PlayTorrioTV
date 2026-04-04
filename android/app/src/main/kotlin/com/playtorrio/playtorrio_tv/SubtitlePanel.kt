package com.playtorrio.playtorrio_tv

import android.animation.ObjectAnimator
import android.content.Context
import android.net.Uri
import android.util.AttributeSet
import android.util.Log
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.Charset
import android.widget.FrameLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import org.videolan.libvlc.MediaPlayer

class SubtitlePanel @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    private val panelRoot: View
    private val panelTitle: TextView
    private val offButton: TextView
    private val recyclerView: RecyclerView
    private val closeButton: TextView

    private val trackAdapter: SubtitlePanelAdapter
    private val languageAdapter: LanguageListAdapter

    private var mediaPlayer: MediaPlayer? = null
    private var activeTrackId: String? = null
    private var isVisible = false
    private var isShowingLanguages = true
    private var currentLanguage: String? = null

    // Grouped subtitle data: language display name → tracks
    private var subtitlesByLanguage = linkedMapOf<String, MutableList<SubtitleTrack>>()

    // ISO 639-2 (3-letter) to ISO 639-1 (2-letter) mapping
    private val iso639ToTwoLetter = mapOf(
        "eng" to "en", "ara" to "ar", "fre" to "fr", "fra" to "fr",
        "spa" to "es", "ger" to "de", "deu" to "de", "ita" to "it",
        "por" to "pt", "rus" to "ru", "jpn" to "ja", "kor" to "ko",
        "chi" to "zh", "zho" to "zh", "hin" to "hi", "tur" to "tr",
        "pol" to "pl", "dut" to "nl", "nld" to "nl", "swe" to "sv",
        "nor" to "no", "dan" to "da", "fin" to "fi", "gre" to "el",
        "ell" to "el", "heb" to "he", "tha" to "th", "vie" to "vi",
        "ind" to "id", "cze" to "cs", "ces" to "cs", "rum" to "ro",
        "ron" to "ro", "hun" to "hu", "bul" to "bg", "hrv" to "hr",
        "srp" to "sr", "slk" to "sk", "ukr" to "uk", "per" to "fa",
        "fas" to "fa", "urd" to "ur", "ben" to "bn", "tam" to "ta",
        "tel" to "te", "mal" to "ml", "mkd" to "mk"
    )

    init {
        LayoutInflater.from(context).inflate(R.layout.subtitle_panel, this, true)

        panelRoot = findViewById(R.id.subtitlePanelRoot)
        panelTitle = findViewById(R.id.panelTitle)
        offButton = findViewById(R.id.offButton)
        recyclerView = findViewById(R.id.subtitleRecyclerView)
        closeButton = findViewById(R.id.closeButton)

        recyclerView.layoutManager = LinearLayoutManager(context)

        trackAdapter = SubtitlePanelAdapter(
            onSubtitleSelected = { track -> onSubtitleSelected(track) }
        )
        languageAdapter = LanguageListAdapter(
            onLanguageSelected = { language -> showTracksForLanguage(language) }
        )

        recyclerView.adapter = languageAdapter

        setupOffButton()
        setupCloseButton()
    }

    private fun normalizeLanguage(code: String): String {
        // Already a display name (e.g. "Arabic" from levrx)
        if (code.length > 3 && code[0].isUpperCase()) return code

        val twoLetter = iso639ToTwoLetter[code.lowercase()] ?: code.lowercase()
        return try {
            java.util.Locale(twoLetter).getDisplayLanguage(java.util.Locale.ENGLISH)
                .takeIf { it.isNotEmpty() && it != twoLetter }
                ?: code.replaceFirstChar { it.uppercase() }
        } catch (e: Exception) {
            code.replaceFirstChar { it.uppercase() }
        }
    }

    private fun setupOffButton() {
        offButton.setOnClickListener {
            turnOffSubtitles()
        }

        offButton.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_DOWN -> {
                        recyclerView.post {
                            recyclerView.findViewHolderForAdapterPosition(0)?.itemView?.requestFocus()
                        }
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_UP -> true
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> true
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        turnOffSubtitles()
                        true
                    }
                    else -> false
                }
            } else false
        }

        offButton.setOnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                offButton.setBackgroundColor(0xFF1A1A1A.toInt())
            } else {
                offButton.setBackgroundColor(0x00000000)
            }
        }
    }

    private fun setupCloseButton() {
        closeButton.setOnClickListener {
            dismiss()
        }

        closeButton.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        dismiss()
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> true
                    else -> false
                }
            } else false
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Centralized BACK key handling for two-level navigation
        if (isVisible && event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_UP) {
                handleBackPress()
            }
            return true // Consume both DOWN and UP
        }
        return super.dispatchKeyEvent(event)
    }

    private fun handleBackPress() {
        if (isShowingLanguages) {
            dismiss()
        } else {
            showLanguages()
        }
    }

    fun setMediaPlayer(player: MediaPlayer) {
        this.mediaPlayer = player
    }

    fun show(subtitles: List<SubtitleTrack>, activeId: String?) {
        if (isVisible) return

        activeTrackId = activeId
        trackAdapter.activeTrackId = activeId

        // Group subtitles by normalized language name
        subtitlesByLanguage = linkedMapOf()
        for (track in subtitles) {
            val langName = normalizeLanguage(track.language)
            subtitlesByLanguage.getOrPut(langName) { mutableListOf() }.add(track)
        }

        // Sort: English first, then Arabic, then alphabetically
        val sorted = subtitlesByLanguage.entries.sortedWith(
            compareBy<Map.Entry<String, MutableList<SubtitleTrack>>> {
                when {
                    it.key.equals("English", ignoreCase = true) -> 0
                    it.key.equals("Arabic", ignoreCase = true) -> 1
                    else -> 2
                }
            }.thenBy { it.key }
        )
        subtitlesByLanguage = linkedMapOf()
        for (entry in sorted) {
            subtitlesByLanguage[entry.key] = entry.value
        }

        panelRoot.visibility = View.VISIBLE
        isVisible = true
        isShowingLanguages = true
        currentLanguage = null

        showLanguages()

        // Slide in animation
        panelRoot.translationX = panelRoot.width.toFloat()
        ObjectAnimator.ofFloat(panelRoot, "translationX", 0f).apply {
            duration = 200
            start()
        }
    }

    private fun showLanguages() {
        isShowingLanguages = true
        panelTitle.text = "Subtitles"

        val items = subtitlesByLanguage.map { (name, tracks) ->
            LanguageListAdapter.LanguageItem(name, tracks.size)
        }

        recyclerView.adapter = languageAdapter
        languageAdapter.submitList(items)

        recyclerView.post {
            if (items.isNotEmpty()) {
                val focusIndex = if (currentLanguage != null) {
                    items.indexOfFirst { it.name == currentLanguage }.takeIf { it >= 0 } ?: 0
                } else 0
                recyclerView.scrollToPosition(focusIndex)
                recyclerView.post {
                    recyclerView.findViewHolderForAdapterPosition(focusIndex)?.itemView?.requestFocus()
                        ?: offButton.requestFocus()
                }
            } else {
                offButton.requestFocus()
            }
        }
    }

    private fun showTracksForLanguage(language: String) {
        val tracks = subtitlesByLanguage[language] ?: return

        isShowingLanguages = false
        currentLanguage = language
        panelTitle.text = "\u25C2  $language"

        recyclerView.adapter = trackAdapter
        trackAdapter.activeTrackId = activeTrackId
        trackAdapter.submitList(tracks)

        recyclerView.post {
            val focusIndex = if (activeTrackId != null) {
                tracks.indexOfFirst { it.id == activeTrackId }.takeIf { it >= 0 } ?: 0
            } else 0
            recyclerView.scrollToPosition(focusIndex)
            recyclerView.post {
                recyclerView.findViewHolderForAdapterPosition(focusIndex)?.itemView?.requestFocus()
                    ?: offButton.requestFocus()
            }
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
    private var onSubtitleChangedCallback: ((String) -> Unit)? = null

    fun setOnDismissListener(callback: () -> Unit) {
        onDismissCallback = callback
    }

    fun setOnSubtitleChangedListener(callback: (String) -> Unit) {
        onSubtitleChangedCallback = callback
    }

    private fun onSubtitleSelected(track: SubtitleTrack) {
        val player = mediaPlayer ?: return

        try {
            Log.d("SubtitlePanel", "Loading subtitle: ${track.label} from ${track.url}")

            // First disable current subtitle
            player.setSpuTrack(-1)

            // Download, detect encoding, convert to UTF-8, and load from local file
            Thread {
                try {
                    val bytes = downloadUrl(track.url)
                    if (bytes == null) {
                        Log.e("SubtitlePanel", "Failed to download subtitle")
                        return@Thread
                    }

                    val utf8Content = convertToUtf8(bytes)
                    val tempFile = File(context.cacheDir, "subtitle_${System.currentTimeMillis()}.srt")
                    tempFile.writeText(utf8Content, Charsets.UTF_8)

                    val uri = Uri.fromFile(tempFile)
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        val success = player.addSlave(
                            org.videolan.libvlc.interfaces.IMedia.Slave.Type.Subtitle, uri, true
                        )
                        Log.d("SubtitlePanel", "Subtitle load result: $success")

                        if (success) {
                            activeTrackId = track.id
                            trackAdapter.activeTrackId = track.id
                            trackAdapter.notifyDataSetChanged()
                            onSubtitleChangedCallback?.invoke(track.id)
                        }
                    }
                } catch (e: Exception) {
                    Log.e("SubtitlePanel", "Failed to download/convert subtitle: ${e.message}", e)
                }
            }.start()

            dismiss()
        } catch (e: Exception) {
            Log.e("SubtitlePanel", "Failed to load subtitle: ${e.message}", e)
        }
    }

    private fun downloadUrl(urlStr: String): ByteArray? {
        return try {
            val url = URL(urlStr)
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            conn.setRequestProperty("User-Agent", "Mozilla/5.0")
            conn.inputStream.use { it.readBytes() }
        } catch (e: Exception) {
            Log.e("SubtitlePanel", "Download error: ${e.message}", e)
            null
        }
    }

    private fun convertToUtf8(bytes: ByteArray): String {
        // Check for BOM
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
            return String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
        }
        if (bytes.size >= 2) {
            if (bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) {
                return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
            }
            if (bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()) {
                return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
            }
        }

        // Try UTF-8 first — if valid, use it
        if (isValidUtf8(bytes)) {
            return String(bytes, Charsets.UTF_8)
        }

        // Not valid UTF-8 — detect encoding by analyzing byte patterns
        val charset = detectNonUtf8Charset(bytes)
        Log.d("SubtitlePanel", "Detected subtitle encoding: ${charset.name()}")
        return String(bytes, charset)
    }

    private fun isValidUtf8(bytes: ByteArray): Boolean {
        var i = 0
        while (i < bytes.size) {
            val b = bytes[i].toInt() and 0xFF
            val seqLen: Int
            when {
                b <= 0x7F -> { i++; continue }
                b in 0xC2..0xDF -> seqLen = 2
                b in 0xE0..0xEF -> seqLen = 3
                b in 0xF0..0xF4 -> seqLen = 4
                else -> return false
            }
            if (i + seqLen > bytes.size) return false
            for (j in 1 until seqLen) {
                if (bytes[i + j].toInt() and 0xC0 != 0x80) return false
            }
            i += seqLen
        }
        return true
    }

    private fun detectNonUtf8Charset(bytes: ByteArray): Charset {
        // Count bytes in Windows-1256 Arabic range (0xC0-0xFF maps to Arabic letters)
        var arabicCount = 0
        var cyrillicCount = 0
        var latin1Count = 0
        var total = 0

        for (b in bytes) {
            val v = b.toInt() and 0xFF
            if (v < 0x80) continue
            total++
            // Windows-1256: 0xC1-0xDA and 0xE1-0xF2 are Arabic letters
            if (v in 0xC1..0xDA || v in 0xE1..0xF2) arabicCount++
            // Windows-1251 Cyrillic: 0xC0-0xFF
            if (v in 0xC0..0xFF) cyrillicCount++
            // Latin-1/Windows-1252: 0xC0-0xFF are accented Latin chars
            if (v in 0xA0..0xFF) latin1Count++
        }

        if (total == 0) return Charsets.ISO_8859_1

        val arabicRatio = arabicCount.toFloat() / total
        // If >40% of high bytes are in Arabic letter ranges, it's likely Windows-1256
        if (arabicRatio > 0.4f) {
            return Charset.forName("Windows-1256")
        }

        // Default to Windows-1252 (Latin) which covers most Western European languages
        return Charset.forName("Windows-1252")
    }

    private fun turnOffSubtitles() {
        val player = mediaPlayer ?: return

        player.setSpuTrack(-1)
        activeTrackId = null
        trackAdapter.activeTrackId = null
        trackAdapter.notifyDataSetChanged()

        // Notify activity
        onSubtitleChangedCallback?.invoke("")

        Log.d("SubtitlePanel", "Subtitles disabled")
        dismiss()
    }
}
