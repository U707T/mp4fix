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
 * 批量修复 / 扫描期间的"尽力保活"服务。
 *
 * 为什么需要它：Android 12+ 对「缓存进程」会很快冻结（cached app freezing），
 * 用户切到别的应用后，纯 Dart Isolate 里的批量修复 / WebDAV 传输会被挂起；
 * 升为前台服务（带一条低优先级通知）后系统就不会冻结进程。
 *
 * ⚠️ 启动方式与崩溃防护（v2.5.2 修复）：
 *  这里刻意 **不用 `startForegroundService()`**，而是用 `startService()` +
 *  服务内「尽力升前台」（`startForeground`）。原因：`startForegroundService`
 *  会给应用加一条"必须尽快调用 startForeground"的**系统义务** —— 一旦
 *  `startForeground` 因任何原因失败（厂商 ROM 的后台限制、系统策略、
 *  通知被拦、dataSync 配额…）而我们又停掉服务，系统会直接**杀掉整个应用**：
 *      "Context.startForegroundService() did not then call Service.startForeground()"
 *  （AOSP ActiveServices："Bringing down service while still waiting for start
 *   foreground ... That is not allowed." → SERVICE_FOREGROUND_CRASH_MSG）
 *  表现为：点下「扫描」就闪退。
 *  现在：升前台成功 → 和以前一样的保活效果；失败 → **静默降级为普通后台
 *  服务**（等同旧版行为），任务照跑，绝不连累应用。
 *
 * 其他设计：
 *  - 只在任务运行期间存在（任务结束立即 stopSelf），不做任何常驻；
 *  - 通知是 IMPORTANCE_LOW、静音、仅一条、可忽略：不打扰用户，也不要求通知权限；
 *  - Android 15+ 的 dataSync 前台服务超时（6 小时 / 24 小时）由 [onTimeout]
 *    安静收尾。
 */
class TaskService : Service() {

    private var foregrounded = false
    private var lastTitle = "MP4 修复器"
    private var lastText = ""
    private var lastProgress = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (intent?.action == ACTION_STOP) {
                stopSelf()
                return START_NOT_STICKY
            }
            val title = intent?.getStringExtra(EXTRA_TITLE)
            if (!title.isNullOrBlank()) lastTitle = title
            lastText = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
            lastProgress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
            ensureForeground()
        } catch (_: Throwable) {
            // 绝不能因为通知 / 保活失败影响主流程（任务本身照常跑）
        }
        return START_NOT_STICKY
    }

    /** 尽力把服务升为前台；已经在前台时只更新通知。 */
    private fun ensureForeground() {
        if (foregrounded) {
            try {
                notificationManager()
                    ?.notify(NOTIFICATION_ID, buildNotification(lastTitle, lastText, lastProgress))
            } catch (_: Throwable) {
                // 忽略：更新失败不影响任务
            }
            return
        }
        // 1) 常规通知（自定义小图标 + 进度条）
        try {
            startAsForeground(buildNotification(lastTitle, lastText, lastProgress))
            foregrounded = true
            return
        } catch (_: Throwable) {
            // 换最小兜底方案
        }
        // 2) 最小兜底通知：只用系统图标，不依赖自定义资源 / 进度条
        try {
            startAsForeground(buildMinimalNotification(lastTitle, lastText))
            foregrounded = true
        } catch (_: Throwable) {
            // 仍然失败 → 安静降级为普通后台服务（等同旧版行为，不再有崩溃）
        }
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notificationManager(): NotificationManager? =
        getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private fun ensureChannel(manager: NotificationManager) {
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
    }

    private fun baseBuilder(title: String, text: String): Notification.Builder {
        val manager = notificationManager()
        if (manager != null) ensureChannel(manager)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
    }

    private fun buildNotification(title: String, text: String, progress: Int): Notification {
        val builder = baseBuilder(title, text)
            .setSmallIcon(R.drawable.ic_stat_task)
            .setProgress(100, progress.coerceIn(0, 100), progress < 0)
        return builder.build()
    }

    /** 兜底通知：系统图标，任何机型上都存在，不依赖自定义资源。 */
    private fun buildMinimalNotification(title: String, text: String): Notification {
        val builder = baseBuilder(title, text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
        return builder.build()
    }

    /** Android 15+：dataSync 前台服务累计超时（6h/24h）时的系统回调 —— 安静收尾。 */
    override fun onTimeout(startId: Int, fgsType: Int) {
        try {
            stopSelf()
        } catch (_: Throwable) {
            // 忽略
        }
    }

    override fun onDestroy() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
            // 忽略
        }
        super.onDestroy()
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

        /**
         * 刻意用 `startService`（而不是 `startForegroundService`）：
         * 后者会给应用加"必须尽快 startForeground"的系统义务，一旦失败就
         * 整个应用被系统杀掉（就是"一按扫描就闪退"的根因）。
         * 保活本身由服务内部的"尽力升前台"完成，失败静默降级。
         */
        private fun send(context: Context, action: String, title: String, text: String, progress: Int) {
            val intent = Intent(context, TaskService::class.java).apply {
                this.action = action
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {
                // 系统不允许（例如后台启动受限）→ 安静放弃，任务照旧跑
            }
        }
    }
}
