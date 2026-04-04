package com.playtorrio.playtorrio_tv

import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView

class SubtitlePanelAdapter(
    private val onSubtitleSelected: (SubtitleTrack) -> Unit
) : ListAdapter<SubtitleTrack, SubtitlePanelAdapter.ViewHolder>(DiffCallback()) {

    var activeTrackId: String? = null

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val root: View = view.findViewById(R.id.subtitleItemRoot)
        val accentBar: View = view.findViewById(R.id.accentBar)
        val label: TextView = view.findViewById(R.id.subtitleLabel)
        val source: TextView = view.findViewById(R.id.subtitleSource)
        val hearingImpairedIcon: TextView = view.findViewById(R.id.hearingImpairedIcon)
        val checkmark: TextView = view.findViewById(R.id.checkmark)

        fun bind(track: SubtitleTrack) {
            label.text = track.label
            source.text = "${track.source} · ${track.format}"
            hearingImpairedIcon.visibility = if (track.isHearingImpaired) View.VISIBLE else View.GONE
            checkmark.visibility = if (track.id == activeTrackId) View.VISIBLE else View.INVISIBLE

            root.setOnClickListener {
                onSubtitleSelected(track)
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
                            onSubtitleSelected(track)
                            true
                        }
                        else -> false
                    }
                } else false
            }
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.subtitle_item, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(getItem(position))
    }

    class DiffCallback : DiffUtil.ItemCallback<SubtitleTrack>() {
        override fun areItemsTheSame(oldItem: SubtitleTrack, newItem: SubtitleTrack) =
            oldItem.id == newItem.id

        override fun areContentsTheSame(oldItem: SubtitleTrack, newItem: SubtitleTrack) =
            oldItem == newItem
    }
}
