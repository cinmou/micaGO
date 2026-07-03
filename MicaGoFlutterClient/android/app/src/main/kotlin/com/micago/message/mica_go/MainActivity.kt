package com.micago.message.mica_go

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "micago/keepalive"
    private val shareChannelName = "micago/share"
    private val shareTargetCategory = "com.micago.message.SHARE_TARGET"
    private var shareChannel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> { startKeepAlive(); result.success(true) }
                    "stop" -> { stopKeepAlive(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> result.success(pendingShare)
                "clearInitialShare" -> {
                    pendingShare = null
                    result.success(true)
                }
                "setShareTargets" -> {
                    result.success(setShareTargets(call.arguments))
                }
                else -> result.notImplemented()
            }
        }
        handleShareIntent(intent, emit = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent, emit = true)
    }

    private fun startKeepAlive() {
        val intent = Intent(this, KeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopKeepAlive() {
        val intent = Intent(this, KeepAliveService::class.java).apply {
            action = KeepAliveService.ACTION_STOP
        }
        startService(intent)
    }

    private fun handleShareIntent(intent: Intent?, emit: Boolean) {
        val payload = sharePayloadFrom(intent) ?: return
        pendingShare = payload
        if (emit) {
            shareChannel?.invokeMethod("onShare", payload)
        }
    }

    private fun sharePayloadFrom(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action ?: return null
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null

        val uris = mutableListOf<String>()
        if (action == Intent.ACTION_SEND_MULTIPLE) {
            val streams = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            streams?.forEach { uris.add(it.toString()) }
        } else {
            val stream = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (stream != null) uris.add(stream.toString())
        }

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (text.isNullOrBlank() && uris.isEmpty()) return null
        return mapOf(
            "action" to action,
            "mimeType" to intent.type,
            "text" to text,
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
            "targetChatGuid" to intent.getStringExtra("micago.share.targetChatGuid"),
            "uris" to uris,
        )
    }

    private fun setShareTargets(raw: Any?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1 || raw !is List<*>) {
            return false
        }
        val manager = getSystemService(ShortcutManager::class.java) ?: return false
        val shortcuts = raw.take(8).mapIndexedNotNull { index, item ->
            val map = item as? Map<*, *> ?: return@mapIndexedNotNull null
            val guid = map["guid"] as? String ?: return@mapIndexedNotNull null
            val title = (map["title"] as? String)?.takeIf { it.isNotBlank() } ?: "micaGO"
            val avatarPath = map["avatarPath"] as? String
            val shortcutIcon = avatarPath
                ?.let { BitmapFactory.decodeFile(it) }
                ?.let { Icon.createWithBitmap(it) }
                ?: Icon.createWithResource(this, R.mipmap.ic_launcher)
            val intent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "text/plain"
                putExtra("micago.share.targetChatGuid", guid)
            }
            ShortcutInfo.Builder(this, "share_${guid.hashCode().toUInt().toString(16)}")
                .setShortLabel(title.take(24))
                .setLongLabel(title)
                .setIcon(shortcutIcon)
                .setIntent(intent)
                .setCategories(setOf(shareTargetCategory))
                .setRank(index)
                .build()
        }
        manager.dynamicShortcuts = shortcuts
        return true
    }
}
