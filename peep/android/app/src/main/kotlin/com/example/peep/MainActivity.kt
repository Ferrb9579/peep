package com.example.peep

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingNotificationContact: String? = null
    private var notificationChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingNotificationContact = intent.getStringExtra("notification_contact")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val contact = intent.getStringExtra("notification_contact") ?: return
        pendingNotificationContact = contact
        notificationChannel?.invokeMethod("openChat", mapOf("contact" to contact))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "peep/screen_share_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ContextCompat.startForegroundService(
                        this,
                        Intent(this, ScreenShareService::class.java),
                    )
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, ScreenShareService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "peep/message_notifications",
        )
        notificationChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val socketUrl = call.argument<String>("socketUrl")
                    val authToken = call.argument<String>("authToken")
                    val username = call.argument<String>("username")
                    if (socketUrl.isNullOrBlank() || authToken.isNullOrBlank() || username.isNullOrBlank()) {
                        result.error("invalid_arguments", "Notification connection details are required.", null)
                        return@setMethodCallHandler
                    }
                    ContextCompat.startForegroundService(
                        this,
                        Intent(this, MessageNotificationService::class.java).apply {
                            action = MessageNotificationService.ACTION_START
                            putExtra(MessageNotificationService.EXTRA_SOCKET_URL, socketUrl)
                            putExtra(MessageNotificationService.EXTRA_AUTH_TOKEN, authToken)
                            putExtra(MessageNotificationService.EXTRA_USERNAME, username)
                        },
                    )
                    result.success(null)
                }
                "stop" -> {
                    startService(
                        Intent(this, MessageNotificationService::class.java).apply {
                            action = MessageNotificationService.ACTION_STOP
                        },
                    )
                    result.success(null)
                }
                "takeInitialContact" -> {
                    result.success(pendingNotificationContact)
                    pendingNotificationContact = null
                }
                else -> result.notImplemented()
            }
        }
    }
}
