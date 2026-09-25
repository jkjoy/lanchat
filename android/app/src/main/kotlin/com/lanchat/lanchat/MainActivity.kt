package com.lanchat.lanchat

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "lanchat_platform"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToPublic" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val name = call.argument<String>("name")
                    if (sourcePath == null || name == null) {
                        result.error("INVALID_ARGS", "sourcePath or name missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val url = saveToDownloads(sourcePath, name)
                        result.success(url)
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                }
                "startKeepAlive" -> {
                    KeepAliveService.start(this)
                    result.success(true)
                }
                "stopKeepAlive" -> {
                    KeepAliveService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToDownloads(sourcePath: String, name: String): String {
        val src = File(sourcePath)
        if (!src.exists()) throw Exception("Source file not found")

        val mimeType = when {
            name.endsWith(".png") -> "image/png"
            name.endsWith(".jpg") || name.endsWith(".jpeg") -> "image/jpeg"
            name.endsWith(".gif") -> "image/gif"
            name.endsWith(".mp4") || name.endsWith(".m4a") -> "audio/mp4"
            name.endsWith(".mp3") -> "audio/mpeg"
            name.endsWith(".txt") -> "text/plain"
            else -> "application/octet-stream"
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ 使用 MediaStore
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/LanChat")
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("Failed to insert MediaStore record")
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(src).use { input ->
                    input.copyTo(output, bufferSize = 256 * 1024)
                }
            }
            return uri.toString()
        } else {
            // Android 9 及以下直接写外部存储
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val targetDir = File(dir, "LanChat")
            targetDir.mkdirs()
            val target = File(targetDir, name)
            src.copyTo(target, overwrite = false)
            return target.absolutePath
        }
    }
}