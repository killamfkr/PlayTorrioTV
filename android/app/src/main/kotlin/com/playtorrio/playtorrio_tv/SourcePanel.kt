package com.playtorrio.playtorrio_tv

import android.animation.ObjectAnimator
import android.content.Context
import android.util.AttributeSet
import android.util.Log
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import org.json.JSONArray
import org.json.JSONObject

data class PlayerSource(
    val url: String,
    val provider: String,
    val quality: String,
    val headers: Map<String, String> = emptyMap()
)

/** Entry in the source panel — either an extracted source or an on-demand provider. */
data class SourceEntry(
    val providerKey: String,     // e.g. "vidlink", "webstreamr_0"
    val providerName: String,    // Display name e.g. "VidLink"
    val source: PlayerSource? = null,  // null = not yet extracted
    val isLoading: Boolean = false
)

class SourcePanel @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    private val panelRoot: View
    private val recyclerView: RecyclerView
    private val closeButton: TextView
    private val adapter: SourceAdapter

    private var isVisible = false
    private var onDismissCallback: (() -> Unit)? = null
    private var onSourceSelectedCallback: ((PlayerSource) -> Unit)? = null
    private var onProviderExtractCallback: ((String) -> Unit)? = null

    init {
        LayoutInflater.from(context).inflate(R.layout.source_panel, this, true)

        panelRoot = findViewById(R.id.sourcePanelRoot)
        recyclerView = findViewById(R.id.sourceRecyclerView)
        closeButton = findViewById(R.id.sourceCloseButton)

        recyclerView.layoutManager = LinearLayoutManager(context)
        adapter = SourceAdapter(
            onSourceSelected = { source -> onSourceSelectedCallback?.invoke(source) },
            onProviderExtract = { key -> onProviderExtractCallback?.invoke(key) },
            onDismiss = { dismiss() }
        )
        recyclerView.adapter = adapter

        setupCloseButton()
    }

    private fun setupCloseButton() {
        closeButton.setOnClickListener { dismiss() }
        closeButton.setOnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (keyCode) {
                    KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                        dismiss(); true
                    }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> true
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

    fun setEntries(entries: List<SourceEntry>, activeUrl: String) {
        adapter.setEntries(entries, activeUrl)
    }

    fun setActiveSource(url: String) {
        adapter.setActiveSource(url)
    }

    fun setOnSourceSelectedListener(callback: (PlayerSource) -> Unit) {
        onSourceSelectedCallback = callback
    }

    fun setOnProviderExtractListener(callback: (String) -> Unit) {
        onProviderExtractCallback = callback
    }

    fun setOnDismissListener(callback: () -> Unit) {
        onDismissCallback = callback
    }

    fun show() {
        if (isVisible || adapter.itemCount == 0) return
        panelRoot.visibility = View.VISIBLE
        isVisible = true
        panelRoot.translationX = panelRoot.width.toFloat()
        ObjectAnimator.ofFloat(panelRoot, "translationX", 0f).apply {
            duration = 200; start()
        }
        recyclerView.post {
            recyclerView.findViewHolderForAdapterPosition(0)?.itemView?.requestFocus()
        }
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
}

class SourceAdapter(
    private val onSourceSelected: (PlayerSource) -> Unit,
    private val onProviderExtract: (String) -> Unit,
    private val onDismiss: () -> Unit
) : RecyclerView.Adapter<SourceAdapter.ViewHolder>() {

    private var entries = listOf<SourceEntry>()
    private var activeUrl = ""

    fun setEntries(newEntries: List<SourceEntry>, activeSourceUrl: String) {
        entries = newEntries
        activeUrl = activeSourceUrl
        notifyDataSetChanged()
    }

    fun setActiveSource(url: String) {
        activeUrl = url
        notifyDataSetChanged()
    }

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val root: View = view.findViewById(R.id.sourceItemRoot)
        val accentBar: View = view.findViewById(R.id.sourceAccentBar)
        val providerLabel: TextView = view.findViewById(R.id.sourceProviderLabel)
        val qualityLabel: TextView = view.findViewById(R.id.sourceQualityLabel)
        val checkmark: TextView = view.findViewById(R.id.sourceCheckmark)
        val loadingSpinner: ProgressBar = view.findViewById(R.id.sourceLoadingSpinner)

        fun bind(entry: SourceEntry) {
            providerLabel.text = entry.providerName

            if (entry.isLoading) {
                qualityLabel.text = "Extracting..."
                qualityLabel.setTextColor(0xFF9C27B0.toInt())
                loadingSpinner.visibility = View.VISIBLE
                checkmark.visibility = View.INVISIBLE
            } else if (entry.source != null) {
                qualityLabel.text = entry.source.quality.ifEmpty { "Ready" }
                qualityLabel.setTextColor(0xFFAAAAAA.toInt())
                loadingSpinner.visibility = View.GONE
                checkmark.visibility = if (entry.source.url == activeUrl) View.VISIBLE else View.INVISIBLE
            } else {
                qualityLabel.text = "Tap to extract"
                qualityLabel.setTextColor(0xFF888888.toInt())
                loadingSpinner.visibility = View.GONE
                checkmark.visibility = View.INVISIBLE
            }

            root.setOnClickListener {
                if (entry.isLoading) return@setOnClickListener
                if (entry.source != null) {
                    onSourceSelected(entry.source)
                } else {
                    onProviderExtract(entry.providerKey)
                }
            }

            root.setOnFocusChangeListener { _, hasFocus ->
                if (hasFocus) {
                    root.scaleX = 1.05f; root.scaleY = 1.05f
                    root.setBackgroundColor(0xFF1A1A1A.toInt())
                    accentBar.visibility = View.VISIBLE
                } else {
                    root.scaleX = 1.0f; root.scaleY = 1.0f
                    root.setBackgroundColor(0x00000000)
                    accentBar.visibility = View.INVISIBLE
                }
            }

            root.setOnKeyListener { _, keyCode, event ->
                if (event.action == KeyEvent.ACTION_DOWN) {
                    when (keyCode) {
                        KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> true
                        KeyEvent.KEYCODE_DPAD_DOWN -> adapterPosition == itemCount - 1
                        KeyEvent.KEYCODE_DPAD_UP -> adapterPosition == 0
                        KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                            if (entry.isLoading) {
                                true
                            } else if (entry.source != null) {
                                onSourceSelected(entry.source); true
                            } else {
                                onProviderExtract(entry.providerKey); true
                            }
                        }
                        KeyEvent.KEYCODE_BACK -> { onDismiss(); true }
                        else -> false
                    }
                } else false
            }
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context).inflate(R.layout.source_item, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(entries[position])
    }

    override fun getItemCount() = entries.size
}
