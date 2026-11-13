package dev.iyscode.movil.assistant

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.iyscode.movil.MainActivity

/** Local notifications for daemon tasks, new mail and confirmed actions. */
class Notifier(private val context: Context) {
    companion object {
        const val CHANNEL_DAEMON = "isycode_daemon"
        const val CHANNEL_GOOGLE = "isycode_google"
        const val EXTRA_OPEN_ASSISTANT = "open_assistant"
    }

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL_DAEMON, "Tareas de tu PC",
                NotificationManager.IMPORTANCE_HIGH).apply { description = "Avisos del daemon de iSyCode e IsyMCP" })
            manager.createNotificationChannel(NotificationChannel(CHANNEL_GOOGLE, "Google",
                NotificationManager.IMPORTANCE_DEFAULT).apply { description = "Correos nuevos y acciones confirmadas" })
        }
    }

    fun canPost(): Boolean = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun post(channel: String, id: String, title: String, body: String) {
        if (!canPost()) return
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA_OPEN_ASSISTANT, true)
        val open = PendingIntent.getActivity(context, id.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title.take(80))
            .setContentText(body.take(160))
            .setStyle(NotificationCompat.BigTextStyle().bigText(body.take(600)))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id.hashCode(), notification) }
    }
}
