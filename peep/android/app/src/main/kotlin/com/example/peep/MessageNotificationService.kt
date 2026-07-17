package com.example.peep

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.TimeUnit

/**
 * Keeps one authenticated, metadata-only socket alive while the account is
 * signed in. Message ciphertext is never delivered to this service; it only
 * refreshes the encrypted mailbox summary and displays a system notification.
 */
class MessageNotificationService : Service() {
    companion object {
        private const val LOG_TAG = "PeepNotifications"
        const val ACTION_START = "com.example.peep.notifications.START"
        const val ACTION_STOP = "com.example.peep.notifications.STOP"
        const val EXTRA_SOCKET_URL = "socket_url"
        const val EXTRA_AUTH_TOKEN = "auth_token"
        const val EXTRA_USERNAME = "username"

        private const val CONNECTION_CHANNEL_ID = "peep_connection"
        private const val MESSAGE_CHANNEL_ID = "peep_messages"
        private const val CONNECTION_NOTIFICATION_ID = 4101
        private const val FIRST_MESSAGE_NOTIFICATION_ID = 4200
        private const val PREFS_FILE = "peep.notification.connection"
        private const val SOCKET_URL_KEY = "socket_url"
        private const val AUTH_TOKEN_KEY = "auth_token"
        private const val USERNAME_KEY = "username"
    }

    private val client = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
    private var socket: WebSocket? = null
    private var socketUrl: String? = null
    private var authToken: String? = null
    private var username: String? = null
    private var shouldRun = false
    private var reconnectAttempt = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shouldRun = false
                socket?.close(1000, "Signed out")
                socket = null
                preferences().edit().clear().apply()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                socketUrl = intent.getStringExtra(EXTRA_SOCKET_URL)
                authToken = intent.getStringExtra(EXTRA_AUTH_TOKEN)
                username = intent.getStringExtra(EXTRA_USERNAME)
                saveConfiguration()
            }
            else -> restoreConfiguration()
        }

        if (socketUrl.isNullOrBlank() || authToken.isNullOrBlank() || username.isNullOrBlank()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!BuildConfig.DEBUG && socketUrl?.startsWith("wss://") != true) {
            stopSelf()
            return START_NOT_STICKY
        }

        shouldRun = true
        createChannels()
        startForeground(CONNECTION_NOTIFICATION_ID, connectionNotification())
        connect()
        return START_STICKY
    }

    override fun onDestroy() {
        shouldRun = false
        socket?.close(1000, "Service stopped")
        client.dispatcher.executorService.shutdown()
        super.onDestroy()
    }

    private fun connect() {
        val url = socketUrl ?: return
        socket?.cancel()
        socket = client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    reconnectAttempt = 0
                    Log.d(LOG_TAG, "Notification socket connected.")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    val event = runCatching { JSONObject(text) }.getOrNull() ?: return
                    if (event.optString("type") != "mailbox-ready") return
                    val sender = event.optString("from").trim()
                    if (sender.isNotEmpty()) {
                        Log.d(LOG_TAG, "Mailbox event received.")
                        refreshMailbox(sender)
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    Log.w(LOG_TAG, "Notification socket disconnected.", t)
                    scheduleReconnect()
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    Log.d(LOG_TAG, "Notification socket closed: $code")
                    scheduleReconnect()
                }
            },
        )
    }

    private fun scheduleReconnect() {
        if (!shouldRun) return
        val delay = minOf(60_000L, 1_000L shl reconnectAttempt.coerceAtMost(5))
        reconnectAttempt += 1
        android.os.Handler(mainLooper).postDelayed({
            if (shouldRun) connect()
        }, delay)
    }

    private fun refreshMailbox(sender: String) {
        val token = authToken ?: return
        val endpoint = mailboxEndpoint() ?: return
        val body = JSONObject().put("token", token).toString()
            .toRequestBody("application/json; charset=utf-8".toMediaType())
        client.newCall(Request.Builder().url(endpoint).post(body).build()).enqueue(
            object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                    Log.w(LOG_TAG, "Mailbox refresh failed.", e)
                }

                override fun onResponse(call: okhttp3.Call, response: Response) {
                    response.use {
                        if (!it.isSuccessful) {
                            Log.w(LOG_TAG, "Mailbox refresh returned ${it.code}.")
                            return
                        }
                        val responseBody = it.body ?: return
                        val root = runCatching { JSONObject(responseBody.string()) }.getOrNull() ?: return
                        val chats = root.optJSONArray("chats") ?: return
                        var unreadCount = 1
                        for (index in 0 until chats.length()) {
                            val chat = chats.optJSONObject(index) ?: continue
                            if (chat.optString("contactUsername") == sender) {
                                unreadCount = chat.optInt("unreadCount", 1).coerceAtLeast(1)
                                break
                            }
                        }
                        showMessageNotification(sender, unreadCount)
                        Log.d(LOG_TAG, "Message notification displayed.")
                    }
                }
            },
        )
    }

    private fun mailboxEndpoint(): String? = runCatching {
        val source = URI(socketUrl)
        val scheme = if (source.scheme.equals("wss", ignoreCase = true)) "https" else "http"
        URI(scheme, null, source.host, source.port, "/api/mailbox/list", null, null).toString()
    }.getOrNull()

    private fun createChannels() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CONNECTION_CHANNEL_ID,
                "Connection status",
                NotificationManager.IMPORTANCE_MIN,
            ).apply { description = "Keeps Peep ready for new messages." },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = "New encrypted message alerts." },
        )
    }

    private fun connectionNotification(): Notification = NotificationCompat.Builder(this, CONNECTION_CHANNEL_ID)
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle("Peep is ready")
        .setContentText("Listening securely for new messages")
        .setOngoing(true)
        .setSilent(true)
        .build()

    private fun showMessageNotification(sender: String, unreadCount: Int) {
        val detail = if (unreadCount == 1) {
            "New encrypted message from $sender"
        } else {
            "$unreadCount new encrypted messages from $sender"
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("notification_contact", sender)
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            sender.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Peep")
            .setContentText(detail)
            .setStyle(NotificationCompat.BigTextStyle().bigText(detail))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        getSystemService(NotificationManager::class.java).notify(
            FIRST_MESSAGE_NOTIFICATION_ID + (sender.hashCode() and 0x0fff),
            notification,
        )
    }

    private fun saveConfiguration() {
        val url = socketUrl ?: return
        val token = authToken ?: return
        val account = username ?: return
        preferences().edit()
            .putString(SOCKET_URL_KEY, url)
            .putString(AUTH_TOKEN_KEY, token)
            .putString(USERNAME_KEY, account)
            .apply()
    }

    private fun restoreConfiguration() {
        preferences().also {
            socketUrl = it.getString(SOCKET_URL_KEY, null)
            authToken = it.getString(AUTH_TOKEN_KEY, null)
            username = it.getString(USERNAME_KEY, null)
        }
    }

    private fun preferences(): SharedPreferences {
        val key = MasterKey.Builder(applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            applicationContext,
            PREFS_FILE,
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }
}
