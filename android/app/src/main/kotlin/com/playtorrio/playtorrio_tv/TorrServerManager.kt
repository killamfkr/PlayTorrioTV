package com.playtorrio.playtorrio_tv

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Manages TorrServer as a subprocess.
 *
 * The TorrServer binary is bundled in jniLibs as libtorrserver.so. Android
 * extracts it to the app's nativeLibraryDir which is executable. We launch it
 * on localhost with its HTTP API for adding/streaming/removing torrents.
 */
class TorrServerManager(private val context: Context) {

    companion object {
        private const val TAG = "TorrServerManager"
        const val DEFAULT_PORT = 8090
    }

    private var process: Process? = null
    var port: Int = DEFAULT_PORT; private set

    val isRunning: Boolean get() = process?.isAlive == true

    fun start(listenPort: Int = DEFAULT_PORT): Boolean {
        if (isRunning) {
            Log.d(TAG, "TorrServer already running on port $port")
            return true
        }

        val binaryPath = File(context.applicationInfo.nativeLibraryDir, "libtorrserver.so")
        if (!binaryPath.exists()) {
            Log.e(TAG, "TorrServer binary not found at ${binaryPath.absolutePath}")
            return false
        }

        val dataDir = File(context.filesDir, "torr_data")
        dataDir.mkdirs()

        port = listenPort

        try {
            val pb = ProcessBuilder(
                binaryPath.absolutePath,
                "-p", "$port",
                "-d", dataDir.absolutePath,
                "-k"
            )
            pb.redirectErrorStream(true)

            process = pb.start()
            Log.d(TAG, "TorrServer started on port $port")

            // Log output in background thread
            Thread {
                try {
                    process?.inputStream?.bufferedReader()?.useLines { lines ->
                        for (line in lines) {
                            Log.d(TAG, line)
                        }
                    }
                } catch (_: Exception) {}
            }.start()

            // Wait for the server to be ready
            Thread.sleep(2000)

            return isRunning
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start TorrServer: ${e.message}", e)
            return false
        }
    }

    fun stop() {
        process?.let { p ->
            Log.d(TAG, "Stopping TorrServer")
            p.destroy()
            try {
                p.waitFor()
            } catch (_: Exception) {}
            process = null
        }
    }
}
