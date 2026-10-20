package com.u707t.mp4fix

import android.app.ActivityManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.net.Inet4Address
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * 平台通道：补足插件做不到的两件事 ——
 *
 *  1) 把修复产物写进用户选择的 SAF 文件夹（saf_util 只读，没有写入 API）；
 *     写入策略：`name.mp4fix-part` → 校验大小 → **把同名旧文件改名为 `.mp4fix-bak`
 *     让位**（而不是先删）→ 改名转正 → 清理备份；任一步失败都会尝试还原旧文件，
 *     避免"旧文件已删、新文件没写成"的数据丢失窗口。
 *  2) 把 `content://` 输入复制到应用缓存，供纯 Dart 引擎随机读取。
 */
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installCrashLogger()
    }

    /**
     * 把未捕获的 Java/Kotlin 异常写进 `filesDir/crash_last.txt`，
     * 供界面「复制诊断信息」读取。
     *
     * 像"点一下扫描就闪退"这类系统级崩溃（例如 RemoteServiceException）
     * 完全发生在 Dart 之外，只能靠这张底牌远程排查。
     */
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                File(filesDir, CRASH_FILE).writeText(
                    "time=" + System.currentTimeMillis() + "\n" +
                        Log.getStackTraceString(throwable),
                )
            } catch (_: Throwable) {
                // 忽略：记录崩溃不能引发新的崩溃
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 落位取消标记（SAF 写入 / 下载目录写入 / 复制到缓存）。
     *
     * 这些写入动辄几百 MB 到几 GB，`copyTo` 期间 Dart 侧再怎么置取消标记都没用 ——
     * 用户点了「停止」只能干等到复制结束。写入循环里检查这个标记就能及时中断，
     * 而且中断时原文件没有任何改动（`.part` 会被删掉、`.bak` 会还原）。
     *
     * **为什么是「代数」而不是布尔值**：并行修复时同一时刻可能有 2~3 个写入在跑。
     * 以前每次写调用的开头都 `set(false)`，一个任务开始写就会把别的任务刚收到的
     * 取消标记擦掉；现在每个写入开始时记下当前代数，取消时把代数 +1 ——
     * 只有「开始之后发生过取消」的写入才会中断，互不干扰。
     */
    private val cancelEpoch = java.util.concurrent.atomic.AtomicLong(0)

    /** 缓存文件序号：并行复制时避免同一纳秒撞名（同名不同目录的文件）。 */
    private val cacheSeq = java.util.concurrent.atomic.AtomicLong(0)

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancelPlatformWrite" -> {
                cancelEpoch.incrementAndGet()
                result.success(null)
            }

            // 批量开始时向平台要一次当前取消代数，之后这一批的写入都带着它：
            // 停止之后才开始的拷贝也会立刻中止（并行时的任务切换窗口）。
            "writeEpoch" -> result.success(cancelEpoch.get())
            "writeToTree" -> {
                val tree = call.argument<String>("treeUri")?.let(Uri::parse)
                val name = call.argument<String>("name")
                val sourcePath = call.argument<String>("sourcePath")
                if (tree == null || name.isNullOrBlank() || sourcePath.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                val relativeDir = call.argument<String>("relativeDir")
                val epoch = call.argument<Number>("epoch")?.toLong()
                runInBackground(result) {
                    writeToTree(tree, name, File(sourcePath), relativeDir, epoch).toString()
                }
            }

            "copyToCache" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                val name = call.argument<String>("name") ?: "input.bin"
                if (uri == null) {
                    result.error("bad_args", "缺少 uri", null)
                    return
                }
                val epoch = call.argument<Number>("epoch")?.toLong()
                runInBackground(result) { copyToCache(uri, name, epoch) }
            }

            "prefetchForInspect" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.error("bad_args", "缺少 uri", null)
                    return
                }
                runInBackground(result) { prefetchForInspect(uri) }
            }

            "saveToDownloads" -> {
                val name = call.argument<String>("name")
                val sourcePath = call.argument<String>("sourcePath")
                if (name.isNullOrBlank() || sourcePath.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                val relativeDir = call.argument<String>("relativeDir")
                val epoch = call.argument<Number>("epoch")?.toLong()
                runInBackground(result) {
                    saveToDownloads(name, File(sourcePath), relativeDir, epoch)
                }
            }

            "deleteDocument" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.error("bad_args", "缺少 uri", null)
                    return
                }
                runCatching { DocumentsContract.deleteDocument(contentResolver, uri) }
                result.success(null)
            }

            // 扫描整个 SAF 文件夹，找出「只剩 .mp4fix-bak、正式名不见了」的残留
            // （v2.7.0 及以前的事故现场），返回可恢复清单。
            "listBackupLeftovers" -> {
                val tree = call.argument<String>("treeUri")?.let(Uri::parse)
                if (tree == null) {
                    result.error("bad_args", "缺少 treeUri", null)
                    return
                }
                runInBackground(result) { listBackupLeftovers(tree) }
            }

            // 把某个 .mp4fix-bak 改回正式名（数据恢复）。
            // 传 parentUri 而不是只传名字 —— 残留文件可能在子目录里（递归扫描发现的），
            // 只在根目录找会漏掉绝大多数。
            "restoreBackup" -> {
                val tree = call.argument<String>("treeUri")?.let(Uri::parse)
                val backupName = call.argument<String>("backupName")
                val parentUri = call.argument<String>("parentUri")?.let(Uri::parse)
                if (tree == null || backupName.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                runInBackground(result) {
                    restoreBackupToOriginal(tree, backupName, parentUri)
                }
            }

            "existsInTree" -> {
                val tree = call.argument<String>("treeUri")?.let(Uri::parse)
                val name = call.argument<String>("name")
                if (tree == null || name.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                val exists = runCatching {
                    findRelative(tree, name) != null
                }.getOrElse { true } // 查询失败当作"还在"，别平白让复用失效
                result.success(exists)
            }

            "existsInDownloads" -> {
                val raw = call.argument<String>("name")
                if (raw.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                // name 可能是带子目录的相对路径（`sub/a.mp4`）
                val rel = raw.replace('\\', '/').trim('/')
                val slash = rel.lastIndexOf('/')
                val dir = if (slash >= 0) rel.substring(0, slash) else null
                val file = if (slash >= 0) rel.substring(slash + 1) else rel
                val exists = runCatching { findDownload(file, dir) != null }
                    .getOrElse { true }
                result.success(exists)
            }

            "startTaskService" -> {
                TaskService.start(
                    this,
                    call.argument<String>("title") ?: "MP4 修复器",
                    call.argument<String>("text") ?: "",
                    call.argument<Int>("progress") ?: -1,
                )
                result.success(null)
            }

            "updateTaskService" -> {
                TaskService.update(
                    this,
                    call.argument<String>("title") ?: "MP4 修复器",
                    call.argument<String>("text") ?: "",
                    call.argument<Int>("progress") ?: -1,
                )
                result.success(null)
            }

            "stopTaskService" -> {
                TaskService.stop(this)
                result.success(null)
            }

            // WebDAV 主机栏的「读取默认网关」按钮：快速取本机所在网段的地址。
            "defaultGateway" -> result.success(defaultGateway())

            // 并行度自适应：入门机（isLowRamDevice）内存吃紧，少开几个 Isolate
            "deviceProfile" -> {
                val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                result.success(
                    mapOf(
                        "lowRam" to (am?.isLowRamDevice ?: false),
                        "memoryClassMb" to (am?.memoryClass ?: 0),
                        "cores" to Runtime.getRuntime().availableProcessors(),
                    )
                )
            }

            "readLastCrash" -> {
                val crash = try {
                    val f = File(filesDir, CRASH_FILE)
                    if (!f.exists()) null else mapOf(
                        "text" to f.readText(),
                        "time" to f.lastModified(),
                    )
                } catch (_: Exception) {
                    null
                }
                result.success(crash)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 默认网关（一般就是路由器地址），读不到返回 null。
     *
     * WebDAV 主机栏的「读取默认网关」按钮用它快速取本机所在网段的地址。
     * 走 ConnectivityManager 而不是 `/proc/net/route`：Android 10 起普通应用读
     * `/proc/net/route` 会被 SELinux 拒掉，而 LinkProperties 是官方接口；
     * `ACCESS_NETWORK_STATE` 是普通权限，装包即授予，不会弹授权框。
     */
    private fun defaultGateway(): String? = runCatching {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return@runCatching null
        val props = cm.getLinkProperties(network) ?: return@runCatching null
        props.routes
            .firstOrNull { route ->
                val gateway = route.gateway
                route.isDefaultRoute &&
                    gateway is Inet4Address &&
                    !gateway.isAnyLocalAddress
            }
            ?.gateway
            ?.hostAddress
    }.getOrNull()

    /// 在后台线程执行大文件 IO，结果回主线程（避免 ANR）。
    private fun runInBackground(
        result: MethodChannel.Result,
        block: () -> Any?,
    ) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: NotSeekableException) {
                // 管道类来源：Dart 侧会退回复制到缓存再处理
                mainHandler.post {
                    result.error("not_seekable", e.message ?: "not seekable", null)
                }
            } catch (e: WriteCancelledException) {
                // 用户取消：不是失败，Dart 侧显示「已取消（原文件未改动）」
                mainHandler.post {
                    result.error("cancelled", e.message ?: "已取消", null)
                }
            } catch (e: Exception) {
                val message = e.message ?: e.javaClass.simpleName
                mainHandler.post { result.error("platform_error", message, null) }
            }
        }.start()
    }

    /** 用户在落位途中点了「停止」。 */
    private class WriteCancelledException(message: String) : IOException(message)

    /**
     * 边复制边检查取消标记。取消时抛 [WriteCancelledException]，
     * 调用方负责清理半成品并还原原文件。
     */
    private fun copyCancellable(
        input: java.io.InputStream,
        output: java.io.OutputStream,
        epoch: Long,
    ) {
        val buf = ByteArray(1 shl 20)
        while (true) {
            if (cancelEpoch.get() != epoch) {
                throw WriteCancelledException("已取消（原文件未改动）")
            }
            val n = input.read(buf)
            if (n < 0) break
            output.write(buf, 0, n)
        }
    }

    // ---------------------------------------------------------------- SAF 写入

    /**
     * 把 [source] 写进 SAF 文件夹 [tree]，覆盖同名文件 [name]。
     *
     * **不变式：任何失败路径下，用户的原文件都必须仍然可访问。**
     *
     * 历史事故（v2.7.0 及以前）：第 4 步 `renameDocument(partUri, name)` 在部分
     * 提供方（百度网盘 / 各类国产 ROM 文件管理器）上会「返回成功但实际没改名」，
     * 或改名成功但随后删除备份失败 —— 结果原文件永久停在 `xxx.mp4fix-bak`，
     * 正式名消失，用户看到满目录 `.mp4fix-bak` 垃圾，原视频「不见了」。
     *
     * 现在的顺序（关键改动）：
     *  1. 写 `.part` → 校验大小；
     *  2. **先确认 .part 存在且完整**（这时还没碰原文件，最安全）；
     *  3. 原文件改名 `.bak`（只让位，不删）；
     *  4. `.part` 改名为正式名，并**用 findChild 复核结果**（不信返回值）；
     *  5. 复核失败 → **无条件把 `.bak` 改回正式名**（这是还原的关键）；
     *  6. 只有确认正式名已就位，才删 `.bak`。
     *
     * 另外：若正式名最终仍然缺失，`.bak` 一律保留（绝不删除），
     * 宁可留一个 `.bak` 让用户手动改回，也不能让数据消失。
     */
    private fun writeToTree(
        tree: Uri,
        name: String,
        source: File,
        relativeDir: String? = null,
        batchEpoch: Long? = null,
    ): Uri {
        val resolver = contentResolver
        // 递归扫描文件夹时产物要落回原子目录。目录按需创建；建不出来就**报错**，
        // 绝不静默写到根目录 —— 那样只是把「子目录同名文件互相覆盖」的问题藏起来。
        val parent = resolveParent(tree, relativeDir)
        val partName = "$name.mp4fix-part"
        val backupName = "$name.mp4fix-bak"
        val epoch = batchEpoch ?: cancelEpoch.get()

        // ---- 1) 写 .part（此时原文件还没被碰过，失败也不影响它）----
        val partUri = findChild(tree, parent, partName)
            ?: createDocument(tree, parent, partName)
        try {
            resolver.openOutputStream(partUri, "wt")?.use { out ->
                source.inputStream().use { input -> copyCancellable(input, out, epoch) }
            } ?: throw IOException("无法打开输出流（所选文件夹不可写）")
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
            throw e
        }

        // ---- 2) 校验 .part 落盘大小；不合格直接放弃，原文件毫发无伤 ----
        val written = source.length()
        val saved = documentSize(partUri)
        if (saved >= 0 && written > 0 && saved != written) {
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
            throw IOException("落盘校验失败（$saved ≠ $written 字节），原文件未改动")
        }

        // ---- 3) 原文件让位（改名 .bak；改名失败就保留原名，绝不删除）----
        var backupUri: Uri? = null
        val existing = findChild(tree, parent, name)
        if (existing != null) {
            // 清掉上一次残留的 .bak（它已被本次的 .bak 取代）
            findChild(tree, parent, backupName)?.let {
                runCatching { DocumentsContract.deleteDocument(resolver, it) }
            }
            val renamed = runCatching {
                DocumentsContract.renameDocument(resolver, existing, backupName)
            }.getOrNull()
            // 复核：改名后 .bak 必须真的能查到，才算让位成功
            val backupNow = findChild(tree, parent, backupName)
            if (renamed != null || backupNow != null) {
                backupUri = backupNow ?: existing
            } else {
                // 改名失败：原文件仍在正式名下。此时**不能**删它，
                // 也不能继续覆盖 —— 直接放弃，保住原文件。
                runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
                throw IOException(
                    "无法让位原文件（$name 改名失败），已中止，原文件未改动"
                )
            }
        }

        // ---- 4) .part → 正式名，并复核 ----
        // 不信 renameDocument 的返回值：部分提供方（百度网盘 / 国产 ROM）改名成功
        // 却返回 null。旧逻辑据此判定「改名失败」→ 走新建+复制兜底 → 而 .part
        // 已经不存在了，复制必然失败 → 回滚原文件并报错。用户看到的是「修完了但
        // 说失败」，其实是白干一次。这里一律以「文件系统里到底有没有」为准。
        runCatching { DocumentsContract.renameDocument(resolver, partUri, name) }
        var finalUri: Uri? = findChild(tree, parent, name)

        if (finalUri == null) {
            // 改名不可用 / 没生效 → 退化为「新建正式文件 + 复制内容」
            val target = runCatching { createDocument(tree, parent, name) }.getOrNull()
            if (target == null) {
                restoreBackup(resolver, tree, parent, backupUri, name)
                runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
                throw IOException("无法创建正式文件 $name，已还原原文件")
            }
            try {
                val copied = resolver.openInputStream(partUri)?.use { input ->
                    resolver.openOutputStream(target, "wt")?.use { out ->
                        copyCancellable(input, out, epoch)
                    } ?: throw IOException("无法写入新文件")
                    true
                } ?: throw IOException("无法读取临时文件")
                if (!copied) throw IOException("复制未完成")
            } catch (e: Exception) {
                runCatching { DocumentsContract.deleteDocument(resolver, target) }
                restoreBackup(resolver, tree, parent, backupUri, name)
                throw e
            }
            // 复制完再复核一次大小，避免「文件建出来了但内容不全」
            val copiedSize = documentSize(target)
            if (written > 0 && copiedSize >= 0 && copiedSize != written) {
                runCatching { DocumentsContract.deleteDocument(resolver, target) }
                restoreBackup(resolver, tree, parent, backupUri, name)
                throw IOException("新文件大小不符（$copiedSize ≠ $written），已还原原文件")
            }
            finalUri = target
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
        } else {
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
        }

        // ---- 5) 最后一道保险：正式名确实存在，才允许删备份 ----
        val confirmed = findChild(tree, parent, name)
        if (confirmed == null) {
            // 正式名不见了 → 立刻还原，绝不留下「原文件只有 .bak」的状态
            restoreBackup(resolver, tree, parent, backupUri, name)
            throw IOException("写入后未能确认 $name 存在，已还原原文件")
        }

        backupUri?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
        return confirmed
    }

    /**
     * 递归扫描 SAF 树，找出「只剩 `.mp4fix-bak`」的残留文件。
     *
     * 返回形如 `[{"backupName": "a.mp4.mp4fix-bak", "originalName": "a.mp4",
     * "size": 123, "parentPath": "/baidu/flyflow", "parentUri": "..."}]` 的列表。
     * 正式名仍然存在的 `.bak` 属于正常中间态，不列出。
     */
    private fun listBackupLeftovers(tree: Uri): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val resolver = contentResolver
        // 栈里存 (目录 documentUri, 展示路径)
        val stack = java.util.ArrayDeque<Pair<Uri, String>>()
        stack.addLast(parentDocumentUri(tree) to "")
        var visited = 0
        while (stack.isNotEmpty() && visited < MAX_SCAN_DIRS) {
            val (dir, rel) = stack.removeLast()
            visited++
            val childrenUri = try {
                DocumentsContract.buildChildDocumentsUriUsingTree(
                    tree, DocumentsContract.getDocumentId(dir)
                )
            } catch (_: Exception) {
                continue
            }
            val names = HashMap<String, Pair<Uri, Long>>()  // name -> (uri, size)
            val dirs = ArrayList<Pair<Uri, String>>()
            try {
                resolver.query(
                    childrenUri,
                    arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                        DocumentsContract.Document.COLUMN_SIZE,
                    ),
                    null, null, null,
                )?.use { c ->
                    while (c.moveToNext()) {
                        val id = c.getString(0) ?: continue
                        val nm = c.getString(1) ?: continue
                        val mime = c.getString(2)
                        val size = if (c.isNull(3)) -1L else c.getLong(3)
                        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            val childRel = if (rel.isEmpty()) nm else "$rel/$nm"
                            dirs.add(uri to childRel)
                        } else {
                            names[nm] = uri to size
                        }
                    }
                }
            } catch (_: Exception) {
                continue
            }
            for ((uri, childRel) in dirs) stack.addLast(uri to childRel)

            for ((nm, pair) in names) {
                if (!nm.endsWith(BAK_SUFFIX)) continue
                val original = nm.removeSuffix(BAK_SUFFIX)
                // 正式名还在 → 正常中间态，跳过
                if (names.containsKey(original)) continue
                out.add(
                    mapOf(
                        "backupName" to nm,
                        "originalName" to original,
                        "size" to pair.second,
                        "parentPath" to rel,
                        "parentUri" to dir.toString(),
                    )
                )
            }
        }
        return out
    }

    /**
     * 把 `xxx.mp4fix-bak` 改回 `xxx`；正式名已存在时不覆盖。
     *
     * [parentUri] 是残留文件所在的目录（递归扫描时带回来的）。为空时退回根目录。
     */
    private fun restoreBackupToOriginal(
        tree: Uri,
        backupName: String,
        parentUri: Uri?,
    ): Boolean {
        val resolver = contentResolver
        val original = backupName.removeSuffix(BAK_SUFFIX)
        val parent = parentUri ?: parentDocumentUri(tree)
        val backup = findChild(tree, parent, backupName) ?: return false
        if (findChild(tree, parent, original) != null) return false  // 不覆盖已有文件
        runCatching { DocumentsContract.renameDocument(resolver, backup, original) }
        return findChild(tree, parent, original) != null
    }

    /**
     * 把让位的 `.bak` 改回正式名。**这是数据安全的最后防线** ——
     * 任何一步失败都必须调用它，确保用户的原文件不会只剩一个 `.bak`。
     */
    private fun restoreBackup(
        resolver: android.content.ContentResolver,
        tree: Uri,
        parent: Uri,
        backupUri: Uri?,
        name: String,
    ) {
        if (backupUri == null) return
        // 正式名已被别的路径占用时先清掉，避免改名冲突
        findChild(tree, parent, name)?.let {
            runCatching { DocumentsContract.deleteDocument(resolver, it) }
        }
        runCatching { DocumentsContract.renameDocument(resolver, backupUri, name) }
        // 复核：还原失败时保留 .bak（数据还在，用户可手动改回）
        findChild(tree, parent, name)
    }


    /**
     * 按相对路径解析（并按需创建）目录。
     *
     * `relativeDir` 为空 → 树根。任一段创建失败就抛错：宁可让这个文件报
     * 「无法创建子目录」，也不要把产物写到错误的目录里（那会覆盖同名文件）。
     */
    private fun resolveParent(tree: Uri, relativeDir: String?): Uri {
        val root = parentDocumentUri(tree)
        if (relativeDir.isNullOrBlank()) return root
        var current = root
        for (segment in relativeDir.split('/', '\\')) {
            if (segment.isBlank() || segment == ".") continue
            if (segment == "..") throw IOException("拒绝写入上级目录（$relativeDir）")
            var next = findChild(tree, current, segment)
            if (next == null) {
                // 并行修复时可能有两个任务同时写到同一个**新建**子目录：
                // 一个先建成，另一个的 createDirectory 就会失败。这里失败后
                // 再查一次 —— 别人建好了同样算成功，不能因此判这个文件保存失败。
                val created = runCatching {
                    createDirectory(tree, current, segment)
                }.getOrNull()
                next = created ?: findChild(tree, current, segment)
            }
            current = next ?: throw IOException(
                "无法在所选文件夹创建子目录「$segment」（该存储可能不支持建目录）"
            )
        }
        return current
    }

    /** 按相对路径逐段查找（`sub/a.mp4` → 子目录里的 a.mp4）。 */
    private fun findRelative(tree: Uri, relativePath: String): Uri? {
        val segments = relativePath.split('/', '\\').filter { it.isNotBlank() }
        if (segments.isEmpty()) return null
        var current = parentDocumentUri(tree)
        for (i in segments.indices) {
            val child = findChild(tree, current, segments[i]) ?: return null
            if (i == segments.lastIndex) return child
            current = child
        }
        return null
    }

    private fun createDirectory(tree: Uri, parent: Uri, name: String): Uri? =
        DocumentsContract.createDocument(
            contentResolver,
            parent,
            DocumentsContract.Document.MIME_TYPE_DIR,
            name,
        )

    private fun parentDocumentUri(tree: Uri): Uri = try {
        DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
    } catch (e: Exception) {
        tree
    }

    private fun findChild(tree: Uri, parent: Uri, name: String): Uri? = try {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree, DocumentsContract.getDocumentId(parent)
        )
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null, null, null,
        )?.use { c ->
            var found: Uri? = null
            while (c.moveToNext()) {
                if (c.getString(1) == name) {
                    found = DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
                    break
                }
            }
            found
        }
    } catch (e: Exception) {
        null
    }

    private fun createDocument(tree: Uri, parent: Uri, name: String): Uri {
        var lastError: Exception? = null
        for (mime in arrayOf("video/mp4", "application/octet-stream")) {
            for (p in arrayOf(parent, tree)) {
                try {
                    DocumentsContract.createDocument(contentResolver, p, mime, name)?.let { return it }
                } catch (e: Exception) {
                    lastError = e
                }
            }
        }
        throw IOException("无法在所选文件夹创建文件 $name：${lastError?.message ?: "未知原因"}")
    }

    private fun documentSize(uri: Uri): Long = try {
        contentResolver.query(
            uri, arrayOf(DocumentsContract.Document.COLUMN_SIZE), null, null, null
        )?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else -1L } ?: -1L
    } catch (e: Exception) {
        -1L
    }

    // ---------------------------------------------------------------- 公共下载目录

    /**
     * 保存到公共「下载/MP4Fix」目录（Android 10+ 走 MediaStore，无需任何权限，用户可见）。
     * 低版本退回应用外部目录（同样不需要权限）。
     *
     * 同名时直接覆盖旧产物 —— 否则 MediaStore 会自动改名成 "xxx (1).mp4"，
     * 反复修复同一部片子就会在下载目录里堆出一串副本。
     */
    private fun saveToDownloads(
        name: String,
        source: File,
        relativeDir: String? = null,
        batchEpoch: Long? = null,
    ): String {
        val resolver = contentResolver
        val epoch = batchEpoch ?: cancelEpoch.get()
        val relDir = mediaRelDir(relativeDir)
        if (Build.VERSION.SDK_INT >= 29) {
            val existing = findDownload(name, relativeDir)
            if (existing != null) {
                try {
                    resolver.openOutputStream(existing, "wt")?.use { out ->
                        source.inputStream().use { input -> copyCancellable(input, out, epoch) }
                    } ?: throw IOException("无法写入下载目录")
                    return "$relDir$name"
                } catch (e: WriteCancelledException) {
                    // 取消：直接冒泡（不要当成「覆盖失败」删掉旧文件再重试一遍）
                    throw e
                } catch (e: Exception) {
                    // 覆盖失败：删掉旧文件后走下面的新建流程
                    runCatching { resolver.delete(existing, null, null) }
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relDir)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("无法在下载目录创建文件")
            try {
                resolver.openOutputStream(uri, "w")?.use { out ->
                    source.inputStream().use { input -> copyCancellable(input, out, epoch) }
                } ?: throw IOException("无法写入下载目录")
            } catch (e: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                throw e
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            return "$relDir$name"
        }
        val base = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "MP4Fix")
        val dir = if (relativeDir.isNullOrBlank()) base else File(base, relativeDir)
        if (!dir.exists()) dir.mkdirs()
        val out = File(dir, name)
        try {
            source.inputStream().use { input ->
                out.outputStream().buffered(1 shl 20).use { o -> copyCancellable(input, o, epoch) }
            }
        } catch (e: Exception) {
            runCatching { out.delete() }
            throw e
        }
        return out.absolutePath
    }

    /** 下载目录的相对路径（MediaStore 要求以 `/` 结尾）。 */
    private fun mediaRelDir(relativeDir: String?): String {
        val base = Environment.DIRECTORY_DOWNLOADS + "/MP4Fix"
        // 过滤空段与 `.` / `..`：相对目录可能来自 WebDAV 的远端目录名，
        // 不能让 MediaStore 的 RELATIVE_PATH 被 `..` 带出 MP4Fix 目录。
        val sub = relativeDir
            ?.trim()
            ?.replace('\\', '/')
            ?.split('/')
            ?.filter { it.isNotBlank() && it != "." && it != ".." }
            ?.joinToString("/")
            ?: ""
        return if (sub.isEmpty()) "$base/" else "$base/$sub/"
    }

    /** 把 RELATIVE_PATH 归一化后比较（有的提供方会带尾斜杠 / 反斜杠）。 */
    private fun sameRelPath(a: String?, b: String): Boolean {
        if (a == null) return false
        val na = a.replace('\\', '/').trim('/')
        val nb = b.replace('\\', '/').trim('/')
        return na.equals(nb, ignoreCase = true)
    }

    /** 在「下载/MP4Fix」里找同名文件（Android 10+）。 */
    private fun findDownload(name: String, relativeDir: String? = null): Uri? {
        if (Build.VERSION.SDK_INT >= 29) {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.RELATIVE_PATH,
            )
            try {
                contentResolver.query(
                    collection,
                    projection,
                    "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                    arrayOf(name),
                    null,
                )?.use { c ->
                    val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val pathCol = c.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                    while (c.moveToNext()) {
                        val rel = if (pathCol >= 0) c.getString(pathCol) else null
                        if (rel == null || !rel.contains("MP4Fix")) continue
                        if (!sameRelPath(rel, mediaRelDir(relativeDir))) continue
                        return ContentUris.withAppendedId(collection, c.getLong(idCol))
                    }
                }
            } catch (e: Exception) {
                return null
            }
            return null
        }
        val base = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "MP4Fix")
        val dir = if (relativeDir.isNullOrBlank()) base else File(base, relativeDir)
        return if (File(dir, name).exists()) Uri.fromFile(File(dir, name)) else null
    }

    // ---------------------------------------------------------------- 只读预取（检测）

    /** 管道类来源（不能 seek / 取不到大小）→ 调用方退回复制到缓存。 */
    private class NotSeekableException(message: String) : IOException(message)

    /**
     * 只读预取"检测所需区域"：每个顶层盒的头部 + 整个 moov + 每个 moof。
     *
     * 与服务端 WebDAV 扫描同一思路：几 GB 的视频只需要读盒头与 moov（分片文件
     * 再加各 moof，通常每个仅几 KB），避免把整份视频复制到缓存。
     * 用 ParcelFileDescriptor 的文件描述符做随机读；来源不支持随机读时抛
     * [NotSeekableException]，Dart 侧自动退回"复制到缓存再检测"。
     */
    private fun prefetchForInspect(uri: Uri): Map<String, Any?> {
        val pfd = contentResolver.openFileDescriptor(uri, "r")
            ?: throw IOException("无法打开文件：$uri")
        pfd.use { desc ->
            // 显式确认可 seek（管道类 provider 不能随机读 → 退回复制）
            if (!isSeekable(desc)) throw NotSeekableException("来源不支持随机读取")
            val statSize = desc.statSize
            val size = if (statSize >= 0) {
                statSize
            } else {
                runCatching {
                    FileInputStream(desc.fileDescriptor).channel.size()
                }.getOrElse { -1L }
            }
            if (size < 0) throw NotSeekableException("无法获取文件大小")

            val channel = FileInputStream(desc.fileDescriptor).channel
            val ranges = ArrayList<Map<String, Any?>>()
            var pos = 0L
            var boxCount = 0
            var moofCount = 0
            try {
                while (pos + 8 <= size) {
                    if (++boxCount > MAX_BOX_COUNT) break
                    val hdr = readAt(channel, pos, 16)
                    if (hdr.size < 8) break
                    var boxSize = (beU32(hdr, 0).toLong() and 0xFFFFFFFFL)
                    var header = 8
                    if (boxSize == 1L) {
                        if (hdr.size < 16) break
                        boxSize = beU64(hdr, 8)
                        header = 16
                    } else if (boxSize == 0L) {
                        boxSize = size - pos
                    }
                    ranges.add(
                        mapOf(
                            "start" to pos,
                            "bytes" to hdr.copyOf(minOf(header, hdr.size)),
                        )
                    )
                    if (boxSize < header || pos + boxSize > size) break
                    val type = String(hdr, 4, 4, Charsets.ISO_8859_1)
                    if (type == "moov" || type == "moof") {
                        val payload = boxSize - header
                        if (type == "moov" && payload > MAX_MOOV) {
                            throw IOException("moov 过大（$payload 字节），已跳过")
                        }
                        if (type == "moof") {
                            if (++moofCount > MAX_FRAGMENTS) {
                                throw IOException("分片数过多（>$MAX_FRAGMENTS），已跳过")
                            }
                            if (payload > MAX_MOOF) {
                                throw IOException("moof 过大（$payload 字节），已跳过")
                            }
                        }
                        if (payload > 0) {
                            val body = readAt(channel, pos + header, payload.toInt())
                            if (body.size.toLong() != payload) {
                                throw IOException("预取读取不完整")
                            }
                            ranges.add(
                                mapOf("start" to pos + header, "bytes" to body)
                            )
                        }
                    }
                    pos += boxSize
                }
            } catch (e: IOException) {
                if (pos == 0L) throw NotSeekableException("来源不支持随机读取")
                throw e
            }
            return mapOf("size" to size, "ranges" to ranges)
        }
    }

    /** 文件描述符是否可 seek（管道 / 套接字类来源为 false）。 */
    private fun isSeekable(desc: ParcelFileDescriptor): Boolean = try {
        android.system.Os.lseek(desc.fileDescriptor, 0L, android.system.OsConstants.SEEK_CUR)
        true
    } catch (e: Exception) {
        false
    }

    /** 从指定偏移读取最多 [len] 字节（PFD 不支持 seek 时抛 IOException）。 */
    private fun readAt(channel: FileChannel, pos: Long, len: Int): ByteArray {
        val buf = ByteBuffer.allocate(len)
        var read = 0
        try {
            while (read < len) {
                val n = channel.read(buf, pos + read)
                if (n <= 0) break
                read += n
            }
        } catch (e: Exception) {
            throw IOException("随机读取失败：${e.message}", e)
        }
        buf.flip()
        val out = ByteArray(read)
        buf.get(out)
        return out
    }

    private fun beU32(b: ByteArray, o: Int): Int =
        ((b[o].toInt() and 0xFF) shl 24) or
            ((b[o + 1].toInt() and 0xFF) shl 16) or
            ((b[o + 2].toInt() and 0xFF) shl 8) or
            (b[o + 3].toInt() and 0xFF)

    private fun beU64(b: ByteArray, o: Int): Long {
        var v = 0L
        for (i in 0 until 8) {
            v = (v shl 8) or (b[o + i].toLong() and 0xFF)
        }
        return v
    }

    // ---------------------------------------------------------------- 输入复制

    private fun copyToCache(
        uri: Uri,
        name: String,
        batchEpoch: Long? = null,
    ): String {
        val dir = File(cacheDir, "imports").apply { mkdirs() }
        val safeName = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(120)
        val out = File(dir, "${System.nanoTime()}-${cacheSeq.incrementAndGet()}-$safeName")
        val epoch = batchEpoch ?: cancelEpoch.get()
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().buffered(1 shl 20).use { o -> copyCancellable(input, o, epoch) }
            } ?: throw IOException("无法读取 $uri")
        } catch (e: Exception) {
            // 取消 / 失败都别把半成品留在缓存里
            runCatching { out.delete() }
            throw e
        }
        return out.absolutePath
    }

    companion object {
        private const val CHANNEL = "mp4fix/platform"
        private const val MAX_MOOV = 64L shl 20 // 预取 moov 上限 64MB（并行扫描时内存 × 并发数）
        private const val MAX_MOOF = 64L shl 20 // 单个 moof 上限 64MB
        private const val MAX_FRAGMENTS = 20000 // 预取 moof 个数上限
        private const val MAX_BOX_COUNT = 50000 // 盒扫描保护上限
        private const val CRASH_FILE = "crash_last.txt" // 上一次未捕获异常（诊断用）

        /** 让位备份的后缀（数据恢复靠它识别残留）。 */
        private const val BAK_SUFFIX = ".mp4fix-bak"

        /** 残留扫描的目录数上限（防止超大目录树卡死）。 */
        private const val MAX_SCAN_DIRS = 20000
    }
}
