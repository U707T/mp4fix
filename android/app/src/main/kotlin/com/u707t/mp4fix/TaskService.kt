package com.u707t.mp4fix

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 批量修复期间的前台服务。
 *
 * 为什么需要它：Android 12+ 对「缓存进程」会很快冻结（cached app freezing），
 * 用户切到别的应用后，纯 Dart Isolate 里的批量修复 / WebDAV 传输会被挂起；
 * 声明一个 `dataSync` 类型的前台服务并带一条低优先级通知，系统就不会冻结进程。
 *
 * 设计要点：
 *  - 只在任务运行期间存在（任务结束立即 stopSelf），不做任何常驻；
 *  - 通知是 IMPORTANCE_LOW、静音、仅一条、可忽略：不打扰用户，也不要求通知权限
 *    （没有 POST_NOTIFICATIONS 时服务照常运行，只是通知不显示）；
 *  - 任何一步失败（如系统限制后台启动前台服务）都安静降级为"和以前一样"，
 *    绝不影响主流程。
 */
class TaskService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val title = (intent?.getStringExtra(EXTRA_TITLE) ?: "").ifBlank { "MP4 修复器" }
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        try {
            startAsForeground(title, text, progress)
        } catch (e: Exception) {
            // 例如 Android 12+ 的后台启动限制：退化为普通后台任务（旧行为）
            runCatching { stopSelf() }
        }
        return START_NOT_STICKY
    }

    private fun startAsForeground(title: String, text: String, progress: Int) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "修复任务",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "批量修复进行中的进度提示（可忽略）"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_task)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(100, progress.coerceIn(0, 100), progress < 0)

        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val CHANNEL_ID = "mp4fix_task"
        private const val NOTIFICATION_ID = 42
        private const val ACTION_START = "com.u707t.mp4fix.task.START"
        private const val ACTION_UPDATE = "com.u707t.mp4fix.task.UPDATE"
        private const val ACTION_STOP = "com.u707t.mp4fix.task.STOP"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"

        fun start(context: Context, title: String, text: String, progress: Int) =
            send(context, ACTION_START, title, text, progress)

        fun update(context: Context, title: String, text: String, progress: Int) =
            send(context, ACTION_UPDATE, title, text, progress)

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, TaskService::class.java))
            } catch (_: Exception) {
                // 忽略
            }
        }

        private fun send(context: Context, action: String, title: String, text: String, progress: Int) {
            val intent = Intent(context, TaskService::class.java).apply {
                this.action = action
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // 系统不允许（例如后台启动受限）→ 安静放弃，任务照旧跑
            }
        }
    }
}
