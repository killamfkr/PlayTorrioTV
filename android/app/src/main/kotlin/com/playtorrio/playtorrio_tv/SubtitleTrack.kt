package com.playtorrio.playtorrio_tv

data class SubtitleTrack(
    val id: String,
    val label: String,
    val language: String,
    val url: String,
    val source: String,
    val format: String,
    val isHearingImpaired: Boolean = false
)
