package com.playtorrio.playtorrio_tv

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val PLAYER_CHANNEL = "com.playtorrio/player"
    private val TORRSERVER_CHANNEL = "com.playtorrio/torrserver"
    private val UPDATER_CHANNEL = "com.playtorrio/updater"

    private var torrServerManager: TorrServerManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Player channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "warmup" -> {
                        VlcProvider.warmup(this)
                        result.success(true)
                    }
                    "launchPlayer" -> {
                        val url = call.argument<String>("url")
                        val title = call.argument<String>("title")
                        val tmdbId = call.argument<Int>("tmdbId") ?: -1
                        val imdbId = call.argument<String>("imdbId") ?: ""
                        val season = call.argument<Int>("season") ?: -1
                        val episode = call.argument<Int>("episode") ?: -1
                        val magnet = call.argument<String>("magnet") ?: ""
                        val fileIdx = call.argument<Int>("fileIdx") ?: -1
                        val backdropPath = call.argument<String>("backdropPath") ?: ""
                        val posterPath = call.argument<String>("posterPath") ?: ""
                        val mediaType = call.argument<String>("mediaType") ?: "movie"
                        val resumePositionMs = (call.argument<Number>("resumePositionMs") ?: 0).toLong()
                        val logoUrl = call.argument<String>("logoUrl") ?: ""
                        if (url == null) {
                            result.error("NO_URL", "URL is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(this, PlayerActivity::class.java).apply {
                                data = Uri.parse(url)
                                putExtra("title", title ?: "")
                                putExtra("tmdbId", tmdbId)
                                putExtra("imdbId", imdbId)
                                putExtra("season", season)
                                putExtra("episode", episode)
                                putExtra("magnet", magnet)
                                putExtra("fileIdx", fileIdx)
                                putExtra("backdropPath", backdropPath)
                                putExtra("posterPath", posterPath)
                                putExtra("mediaType", mediaType)
                                putExtra("resumePositionMs", resumePositionMs)
                                putExtra("logoUrl", logoUrl)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("LAUNCH_FAILED", e.message, null)
                        }
                    }
                    "launchStreamingPlayer" -> {
                        val title = call.argument<String>("title") ?: ""
                        val tmdbId = call.argument<Int>("tmdbId") ?: -1
                        val imdbId = call.argument<String>("imdbId") ?: ""
                        val season = call.argument<Int>("season") ?: -1
                        val episode = call.argument<Int>("episode") ?: -1
                        val backdropPath = call.argument<String>("backdropPath") ?: ""
                        val posterPath = call.argument<String>("posterPath") ?: ""
                        val mediaType = call.argument<String>("mediaType") ?: "movie"
                        val resumePositionMs = (call.argument<Number>("resumePositionMs") ?: 0).toLong()
                        val logoUrl = call.argument<String>("logoUrl") ?: ""
                        try {
                            val intent = Intent(this, PlayerActivity::class.java).apply {
                                putExtra("isStreaming", true)
                                putExtra("title", title)
                                putExtra("tmdbId", tmdbId)
                                putExtra("imdbId", imdbId)
                                putExtra("season", season)
                                putExtra("episode", episode)
                                putExtra("backdropPath", backdropPath)
                                putExtra("posterPath", posterPath)
                                putExtra("mediaType", mediaType)
                                putExtra("resumePositionMs", resumePositionMs)
                                putExtra("logoUrl", logoUrl)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("LAUNCH_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Updater channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceAbi" -> {
                        result.success(android.os.Build.SUPPORTED_ABIS.toList())
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("NO_PATH", "APK path required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            val uri = FileProvider.getUriForFile(
                                this, "${applicationInfo.packageName}.fileprovider", file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // TorrServer engine channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TORRSERVER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        Thread {
                            try {
                                if (torrServerManager == null) {
                                    torrServerManager = TorrServerManager(this@MainActivity)
                                }
                                val port = call.argument<Int>("port") ?: TorrServerManager.DEFAULT_PORT
                                val ok = torrServerManager!!.start(port)
                                runOnUiThread {
                                    if (ok) {
                                        result.success(torrServerManager!!.port)
                                    } else {
                                        result.error("START_FAILED", "Failed to start TorrServer", null)
                                    }
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("START_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }
                    "stop" -> {
                        torrServerManager?.stop()
                        result.success(true)
                    }
                    "isRunning" -> {
                        result.success(torrServerManager?.isRunning == true)
                    }
                    "getNativeLibraryDir" -> {
                        result.success(applicationInfo.nativeLibraryDir)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        torrServerManager?.stop()
        super.onDestroy()
    }
}
