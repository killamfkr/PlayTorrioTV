package com.playtorrio.playtorrio_tv

import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class LanguageListAdapter(
    private val onLanguageSelected: (String) -> Unit
) : RecyclerView.Adapter<LanguageListAdapter.ViewHolder>() {

    data class LanguageItem(
        val name: String,
        val count: Int
    )

    private var items: List<LanguageItem> = emptyList()

    fun submitList(newItems: List<LanguageItem>) {
        items = newItems
        notifyDataSetChanged()
    }

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val root: View = view.findViewById(R.id.languageItemRoot)
        val accentBar: View = view.findViewById(R.id.accentBar)
        val languageName: TextView = view.findViewById(R.id.languageName)
        val subtitleCount: TextView = view.findViewById(R.id.subtitleCount)

        fun bind(item: LanguageItem) {
            languageName.text = item.name
            subtitleCount.text = "${item.count} subtitle${if (item.count != 1) "s" else ""}"

            root.setOnClickListener { onLanguageSelected(item.name) }

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
                        KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> true
                        KeyEvent.KEYCODE_DPAD_DOWN -> adapterPosition == itemCount - 1
                        KeyEvent.KEYCODE_DPAD_UP -> adapterPosition == 0
                        KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                            onLanguageSelected(item.name)
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
            .inflate(R.layout.subtitle_language_item, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(items[position])
    }

    override fun getItemCount() = items.size
}
