package com.example.peep

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat

/** Receives Android's notification-shade reply without opening the activity. */
class InlineReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val contact = intent.getStringExtra(MessageNotificationService.EXTRA_CONTACT).orEmpty()
        val reply = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(MessageNotificationService.REMOTE_INPUT_KEY)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (contact.isEmpty() || reply.isEmpty()) return

        ContextCompat.startForegroundService(
            context,
            Intent(context, MessageNotificationService::class.java).apply {
                action = MessageNotificationService.ACTION_REPLY
                putExtra(MessageNotificationService.EXTRA_CONTACT, contact)
                putExtra(MessageNotificationService.EXTRA_REPLY_TEXT, reply)
            },
        )
    }
}
