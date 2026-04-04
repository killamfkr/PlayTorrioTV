package com.playtorrio.playtorrio_tv

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/**
 * Extracts streaming sources from multiple providers using:
 * - WebStreamr: direct JSON API (HTTP)
 * - VidLink, Mappl, VixSrc, VidNest, 111Movies: headless WebView with JS spy
 */
class StreamExtractorService(private val activity: Activity) {

    /** Container for off-screen WebViews — attached to the activity's root. */
    private var webViewContainer: FrameLayout? = null

    private fun ensureContainer(): FrameLayout {
        if (webViewContainer == null) {
            webViewContainer = FrameLayout(activity).apply {
                // 1x1 container off-screen so WebViews load pages properly
                layoutParams = ViewGroup.LayoutParams(1, 1)
                alpha = 0f  // fully transparent
            }
            val rootView = activity.findViewById<ViewGroup>(android.R.id.content)
            rootView.addView(webViewContainer)
        }
        return webViewContainer!!
    }

    private fun removeContainer() {
        webViewContainer?.let {
            (it.parent as? ViewGroup)?.removeView(it)
        }
        webViewContainer = null
    }

    companion object {
        private const val TAG = "StreamExtractor"
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

        // Timeout per provider WebView extraction
        private const val PROVIDER_TIMEOUT_MS = 30_000L

        private val PROVIDERS = mapOf(
            "vidlink" to ProviderConfig(
                name = "VidLink",
                movieUrl = { id -> "https://vidlink.pro/movie/$id" },
                tvUrl = { id, s, e -> "https://vidlink.pro/tv/$id/$s/$e" }
            ),
            "mappl" to ProviderConfig(
                name = "Mappl",
                movieUrl = { id -> "https://mappl.tv/watch/movie/$id" },
                tvUrl = { id, s, e -> "https://mappl.tv/watch/tv/$id-$s-$e" }
            ),
            "vixsrc" to ProviderConfig(
                name = "VixSrc",
                movieUrl = { id -> "https://vixsrc.to/movie/$id/" },
                tvUrl = { id, s, e -> "https://vixsrc.to/tv/$id/$s/$e/" }
            ),
            "vidnest" to ProviderConfig(
                name = "VidNest",
                movieUrl = { id -> "https://vidnest.fun/movie/$id" },
                tvUrl = { id, s, e -> "https://vidnest.fun/tv/$id/$s/$e" }
            ),
            "111movies" to ProviderConfig(
                name = "111Movies",
                movieUrl = { id -> "https://111movies.com/movie/$id" },
                tvUrl = { id, s, e -> "https://111movies.com/tv/$id/$s/$e" }
            )
        )
    }

    data class ProviderConfig(
        val name: String,
        val movieUrl: (String) -> String,
        val tvUrl: (String, Int, Int) -> String
    )

    data class StreamSource(
        val url: String,
        val provider: String,
        val quality: String = "",
        val headers: Map<String, String> = emptyMap()
    ) {
        fun toJson(): JSONObject = JSONObject().apply {
            put("url", url)
            put("provider", provider)
            put("quality", quality)
            val h = JSONObject()
            headers.forEach { (k, v) -> h.put(k, v) }
            put("headers", h)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val foundSources = CopyOnWriteArrayList<StreamSource>()
    private var onSourceFound: ((StreamSource) -> Unit)? = null
    private var onComplete: (() -> Unit)? = null
    private val activeWebViews = mutableListOf<WebView>()

    /**
     * Start extracting from all providers.
     * [onSourceFound] fires each time a new source is found (incrementally).
     * [onComplete] fires when all providers have finished or timed out.
     */
    fun extractAll(
        tmdbId: String,
        imdbId: String,
        isMovie: Boolean,
        season: Int = 0,
        episode: Int = 0,
        onSourceFound: (StreamSource) -> Unit,
        onComplete: () -> Unit
    ) {
        this.onSourceFound = onSourceFound
        this.onComplete = onComplete
        foundSources.clear()

        var pendingCount = PROVIDERS.size + 1 // +1 for WebStreamr
        val lock = Any()
        val doneProviders = mutableSetOf<String>()

        fun markDone(providerKey: String) {
            synchronized(lock) {
                if (!doneProviders.add(providerKey)) return // already done
                pendingCount--
                if (pendingCount <= 0) {
                    mainHandler.post { this.onComplete?.invoke() }
                }
            }
        }

        // 1. WebStreamr (HTTP API — uses IMDB ID)
        thread(name = "webstreamr") {
            try {
                val sources = fetchWebStreamr(imdbId, isMovie, season, episode)
                sources.forEach { src ->
                    foundSources.add(src)
                    mainHandler.post { onSourceFound(src) }
                }
            } catch (e: Exception) {
                Log.w(TAG, "WebStreamr error: ${e.message}")
            }
            markDone("webstreamr")
        }

        // 2. WebView-based providers (use TMDB ID)
        for ((key, config) in PROVIDERS) {
            val url = if (isMovie) {
                config.movieUrl(tmdbId)
            } else {
                config.tvUrl(tmdbId, season, episode)
            }

            mainHandler.post {
                extractFromWebView(url, config.name) { src ->
                    foundSources.add(src)
                    onSourceFound(src)
                }
                // Timeout fallback
                mainHandler.postDelayed({
                    markDone(key)
                }, PROVIDER_TIMEOUT_MS)
            }
        }
    }

    private fun fetchWebStreamr(
        imdbId: String, isMovie: Boolean, season: Int, episode: Int
    ): List<StreamSource> {
        if (imdbId.isEmpty()) return emptyList()

        val apiUrl = if (isMovie) {
            "https://webstreamr.hayd.uk/stream/movie/$imdbId.json"
        } else {
            "https://webstreamr.hayd.uk/stream/series/$imdbId:$season:$episode.json"
        }

        Log.d(TAG, "WebStreamr: fetching $apiUrl")
        val conn = URL(apiUrl).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = 10_000
        conn.readTimeout = 10_000

        try {
            if (conn.responseCode != 200) return emptyList()

            val body = conn.inputStream.bufferedReader().readText()
            val json = JSONObject(body)
            val streams = json.optJSONArray("streams") ?: return emptyList()

            val results = mutableListOf<StreamSource>()
            for (i in 0 until streams.length()) {
                val s = streams.getJSONObject(i)
                val streamUrl = s.optString("url", "")
                if (streamUrl.isEmpty()) continue

                val name = s.optString("name", "")
                val title = s.optString("title", "")
                val displayTitle = if (name.isNotEmpty()) "$name\n$title" else title

                results.add(
                    StreamSource(
                        url = streamUrl,
                        provider = "WebStreamr",
                        quality = displayTitle
                    )
                )
            }
            Log.d(TAG, "WebStreamr: found ${results.size} sources")
            return results
        } finally {
            conn.disconnect()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun extractFromWebView(
        url: String,
        providerName: String,
        onFound: (StreamSource) -> Unit
    ) {
        var completed = false
        val detectedUrls = mutableListOf<String>()

        val container = ensureContainer()
        val webView = WebView(activity).apply {
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                userAgentString = USER_AGENT
                mediaPlaybackRequiresUserGesture = false
                cacheMode = WebSettings.LOAD_DEFAULT
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                defaultTextEncodingName = "UTF-8"
                @Suppress("DEPRECATION")
                allowFileAccess = false
            }
            // 1x1 invisible — must be attached so the engine loads pages
            layoutParams = ViewGroup.LayoutParams(1, 1)
        }

        container.addView(webView)
        synchronized(activeWebViews) { activeWebViews.add(webView) }

        fun buildHeaders(referer: String): Map<String, String> {
            val uri = android.net.Uri.parse(referer)
            val origin = "${uri.scheme}://${uri.host}"
            return mapOf(
                "User-Agent" to USER_AGENT,
                "Referer" to referer,
                "Origin" to origin
            )
        }

        fun isStreamUrl(rUrl: String): Boolean {
            return ((rUrl.contains(".m3u8") ||
                    rUrl.contains(".mp4") ||
                    rUrl.contains("playlist") ||
                    rUrl.contains("master") ||
                    rUrl.contains(".mpd") ||
                    rUrl.contains("manifest") ||
                    rUrl.contains("heistotron.uk")) &&
                    !rUrl.contains("google"))
        }

        fun selectBestQuality(urls: List<String>): String {
            val qualityOrder =
                listOf("4K", "2160p", "1440p", "1080p", "720p", "480p", "360p")
            for (q in qualityOrder) {
                val match = urls.firstOrNull {
                    it.contains(q, ignoreCase = true)
                }
                if (match != null) return match
            }
            return urls.first()
        }

        var qualityDelayScheduled = false

        fun completeWithBest(referer: String) {
            if (completed || detectedUrls.isEmpty()) return
            completed = true
            val bestUrl = selectBestQuality(detectedUrls)
            val source = StreamSource(
                url = bestUrl,
                provider = providerName,
                quality = extractQualityLabel(bestUrl),
                headers = buildHeaders(referer)
            )
            onFound(source)
            cleanupWebView(webView)
        }

        fun processUrl(rUrl: String, referer: String) {
            if (!isStreamUrl(rUrl) || completed) return

            if (rUrl.contains("/audio/") || rUrl.contains("audio_")) {
                Log.d(TAG, "[$providerName] Audio detected: $rUrl")
                return
            }

            Log.d(TAG, "[$providerName] Stream detected: $rUrl")
            if (!detectedUrls.contains(rUrl)) {
                detectedUrls.add(rUrl)
            }

            // Wait briefly to collect multiple quality variants, then pick best
            if (!qualityDelayScheduled) {
                qualityDelayScheduled = true
                mainHandler.postDelayed({ completeWithBest(referer) }, 2000)
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView, request: WebResourceRequest
            ): WebResourceResponse? {
                val rUrl = request.url.toString()
                mainHandler.post { processUrl(rUrl, url) }
                return super.shouldInterceptRequest(view, request)
            }

            override fun onPageFinished(view: WebView, pageUrl: String?) {
                view.evaluateJavascript(getSpyJs(), null)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                val msg = consoleMessage?.message() ?: return true
                if (msg.contains("PT_EXTRACT:")) {
                    val payload = msg.substringAfter("PT_EXTRACT:").trim()
                        .replace("\"", "").replace("'", "")
                        .replace(Regex("\\[(FETCH|XHR|POSTMESSAGE|ATTR_SRC|MUTATION_SRC|ATTR_DATA-SRC|VIDEO_SRC|SOURCE_SRC|MEDIA_PLAY)\\]"), "")
                        .trim()
                    val streamUrl = if (payload.contains(" | FRAME: ")) {
                        payload.substringBefore(" | FRAME: ")
                    } else payload

                    processUrl(streamUrl, url)
                }
                return true
            }
        }

        // Final cleanup timeout
        mainHandler.postDelayed({
            if (!completed) {
                Log.d(TAG, "[$providerName] Timeout, no sources found")
                cleanupWebView(webView)
            }
        }, PROVIDER_TIMEOUT_MS)

        Log.d(TAG, "[$providerName] Loading: $url")
        webView.loadUrl(url)
    }

    private fun extractQualityLabel(url: String): String {
        val qualityOrder = listOf("4K", "2160p", "1440p", "1080p", "720p", "480p", "360p")
        for (q in qualityOrder) {
            if (url.contains(q, ignoreCase = true)) return q
        }
        return ""
    }

    private fun cleanupWebView(webView: WebView) {
        mainHandler.post {
            try {
                webView.stopLoading()
                webView.loadUrl("about:blank")
                (webView.parent as? ViewGroup)?.removeView(webView)
                webView.destroy()
            } catch (e: Exception) {
                Log.w(TAG, "WebView cleanup error: ${e.message}")
            }
            synchronized(activeWebViews) { activeWebViews.remove(webView) }
        }
    }

    fun cancel() {
        synchronized(activeWebViews) {
            activeWebViews.forEach { wv ->
                mainHandler.post {
                    try {
                        wv.stopLoading()
                        wv.loadUrl("about:blank")
                        (wv.parent as? ViewGroup)?.removeView(wv)
                        wv.destroy()
                    } catch (_: Exception) {}
                }
            }
            activeWebViews.clear()
        }
        mainHandler.post { removeContainer() }
        onSourceFound = null
        onComplete = null
    }

    /** Cancel all active WebView extractions without clearing callbacks. */
    fun cancelActiveWebViews() {
        synchronized(activeWebViews) {
            activeWebViews.forEach { wv ->
                mainHandler.post {
                    try {
                        wv.stopLoading()
                        wv.loadUrl("about:blank")
                        (wv.parent as? ViewGroup)?.removeView(wv)
                        wv.destroy()
                    } catch (_: Exception) {}
                }
            }
            activeWebViews.clear()
        }
    }

    fun getSources(): List<StreamSource> = foundSources.toList()

    /** Get available provider keys (for showing in source panel). */
    fun getProviderKeys(): List<Pair<String, String>> {
        return PROVIDERS.map { (key, config) -> key to config.name }
    }

    /** Extract from WebStreamr only. */
    fun extractWebStreamrOnly(
        imdbId: String,
        isMovie: Boolean,
        season: Int = 0,
        episode: Int = 0,
        onSourceFound: (StreamSource) -> Unit,
        onComplete: () -> Unit
    ) {
        thread(name = "webstreamr") {
            try {
                val sources = fetchWebStreamr(imdbId, isMovie, season, episode)
                sources.forEach { src ->
                    foundSources.add(src)
                    mainHandler.post { onSourceFound(src) }
                }
            } catch (e: Exception) {
                Log.w(TAG, "WebStreamr error: ${e.message}")
            }
            mainHandler.post { onComplete() }
        }
    }

    /** Extract from a single WebView-based provider by key. */
    fun extractProvider(
        providerKey: String,
        tmdbId: String,
        isMovie: Boolean,
        season: Int = 0,
        episode: Int = 0,
        onSourceFound: (StreamSource) -> Unit,
        onComplete: () -> Unit
    ) {
        val config = PROVIDERS[providerKey]
        if (config == null) {
            mainHandler.post { onComplete() }
            return
        }

        val url = if (isMovie) config.movieUrl(tmdbId) else config.tvUrl(tmdbId, season, episode)

        mainHandler.post {
            extractFromWebView(url, config.name) { src ->
                foundSources.add(src)
                onSourceFound(src)
            }
            // Timeout → complete
            mainHandler.postDelayed({ onComplete() }, PROVIDER_TIMEOUT_MS)
        }
    }

    private fun getSpyJs(): String = """
    (function() {
      if (window.pt_raw_injected) return;
      window.pt_raw_injected = true;
      
      const log = (type, url) => {
        if (!url || typeof url !== 'string' || url.startsWith('data:')) return;
        console.log('PT_EXTRACT: [' + type + '] ' + url + ' | FRAME: ' + window.location.href);
      };

      window.open = function() { return null; };
      window.alert = function() { return true; };

      const originalFetch = window.fetch;
      window.fetch = async function(...args) {
        const url = args[0] instanceof Request ? args[0].url : args[0];
        log('FETCH', url);
        return originalFetch.apply(this, args);
      };

      const originalXHROpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        log('XHR', url);
        return originalXHROpen.apply(this, arguments);
      };

      const originalPostMessage = window.postMessage;
      window.postMessage = function(message, targetOrigin, transfer) {
        if (typeof message === 'string') log('POSTMESSAGE', message);
        return originalPostMessage.apply(this, arguments);
      };

      const originalSetAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(name, value) {
        if (name === 'src' || name === 'data-src') log('ATTR_' + name.toUpperCase(), value);
        return originalSetAttribute.apply(this, arguments);
      };

      const observer = new MutationObserver((mutations) => {
        mutations.forEach((mutation) => {
          mutation.addedNodes.forEach((node) => {
            if (node.tagName === 'VIDEO' || node.tagName === 'SOURCE' || node.tagName === 'IFRAME') {
              if (node.src) log('MUTATION_SRC', node.src);
            }
          });
          if (mutation.type === 'attributes' && (mutation.attributeName === 'src' || mutation.attributeName === 'data-src')) {
            log('MUTATION_ATTR', mutation.target.getAttribute(mutation.attributeName));
          }
        });
      });
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });

      const originalPlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function() {
        if (this.src) log('MEDIA_PLAY', this.src);
        return originalPlay.apply(this, arguments);
      };

      const interact = () => {
        const centerX = window.innerWidth / 2;
        const centerY = window.innerHeight / 2;
        for(let i=0; i<3; i++) {
          const el = document.elementFromPoint(centerX, centerY);
          if (el) {
            el.click();
            el.dispatchEvent(new MouseEvent('click', { view: window, bubbles: true, cancelable: true, clientX: centerX, clientY: centerY }));
          }
        }

        const selectors = [
          '.play-icon-main', '.jw-icon-display', '.jw-display-icon-container', '.jw-icon-playback',
          '.jw-button-color', '#play-button', '.play-button', '.v-play-button',
          '.vjs-big-play-button', '[class*="play" i]', '[id*="play" i]',
          '.play-icon', '.play_icon', '.play-btn', '.play_btn',
          '.click_to_play', '.overlay', '#player_overlay', 'button', 'a'
        ];
        selectors.forEach(selector => {
          document.querySelectorAll(selector).forEach(btn => {
            const rect = btn.getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0) {
              const text = (btn.innerText || btn.textContent || '').toLowerCase();
              const id = (btn.id || '').toLowerCase();
              const cls = (btn.className || '').toString().toLowerCase();
              if (text.includes('play') || id.includes('play') || cls.includes('play') || cls.includes('overlay')) {
                btn.click();
              }
            }
          });
        });

        document.querySelectorAll('video').forEach(v => {
          if (v.paused) v.play().catch(() => v.click());
          if (v.src) log('VIDEO_SRC', v.src);
        });
      };
      
      setTimeout(() => {
        interact();
        setInterval(interact, 800);
      }, 1000);
    })();
    """.trimIndent()
}
