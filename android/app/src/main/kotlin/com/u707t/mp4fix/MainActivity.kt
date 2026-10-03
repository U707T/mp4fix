package com.u707t.mp4fix

import android.content.ContentUris
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "writeToTree" -> {
                val tree = call.argument<String>("treeUri")?.let(Uri::parse)
                val name = call.argument<String>("name")
                val sourcePath = call.argument<String>("sourcePath")
                if (tree == null || name.isNullOrBlank() || sourcePath.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                runInBackground(result) { writeToTree(tree, name, File(sourcePath)).toString() }
            }

            "copyToCache" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                val name = call.argument<String>("name") ?: "input.bin"
                if (uri == null) {
                    result.error("bad_args", "缺少 uri", null)
                    return
                }
                runInBackground(result) { copyToCache(uri, name) }
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
                runInBackground(result) { saveToDownloads(name, File(sourcePath)) }
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

            "existsInTree" -> {
                val tree = call.argument<String>("treeUri")?.let(Uri::parse)
                val name = call.argument<String>("name")
                if (tree == null || name.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                val exists = runCatching {
                    findChild(tree, parentDocumentUri(tree), name) != null
                }.getOrElse { true } // 查询失败当作"还在"，别平白让复用失效
                result.success(exists)
            }

            "existsInDownloads" -> {
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                val exists = runCatching { findDownload(name) != null }
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

            else -> result.notImplemented()
        }
    }

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
            } catch (e: Exception) {
                val message = e.message ?: e.javaClass.simpleName
                mainHandler.post { result.error("platform_error", message, null) }
            }
        }.start()
    }

    // ---------------------------------------------------------------- SAF 写入

    private fun writeToTree(tree: Uri, name: String, source: File): Uri {
        val resolver = contentResolver
        val parent = parentDocumentUri(tree)
        val partName = "$name.mp4fix-part"

        // 1) 先写 .part（失败时清理半成品，别留垃圾）
        val partUri = findChild(tree, parent, partName) ?: createDocument(tree, parent, partName)
        try {
            resolver.openOutputStream(partUri, "wt")?.use { out ->
                source.inputStream().use { input -> input.copyTo(out, 1 shl 20) }
            } ?: throw IOException("无法打开输出流（所选文件夹不可写）")
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
            throw e
        }

        // 2) 校验落盘大小
        val written = source.length()
        val saved = documentSize(partUri)
        if (saved >= 0 && written > 0 && saved != written) {
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
            throw IOException("落盘校验失败（$saved ≠ $written 字节）")
        }

        // 3) 同名旧文件先"让位"改名为 .bak（失败才删；不直接删，留出还原余地）
        var backupUri: Uri? = null
        val existing = findChild(tree, parent, name)
        if (existing != null) {
            findChild(tree, parent, "$name.mp4fix-bak")?.let {
                runCatching { DocumentsContract.deleteDocument(resolver, it) }
            }
            val moved = runCatching {
                DocumentsContract.renameDocument(resolver, existing, "$name.mp4fix-bak")
            }.getOrNull() != null
            if (moved) {
                backupUri = existing
            } else {
                runCatching { DocumentsContract.deleteDocument(resolver, existing) }
            }
        }

        // 4) .part → 正式名；提供方不支持改名时退化为"复制到新文档"
        val renamed = runCatching {
            DocumentsContract.renameDocument(resolver, partUri, name)
        }.getOrNull() != null
        if (!renamed) {
            // 创建正式文件失败：先把让位的旧文件还原回去，再报错
            val target = try {
                createDocument(tree, parent, name)
            } catch (e: Exception) {
                backupUri?.let {
                    runCatching { DocumentsContract.renameDocument(resolver, it, name) }
                }
                throw e
            }
            try {
                resolver.openInputStream(partUri)?.use { input ->
                    resolver.openOutputStream(target, "wt")?.use { out ->
                        input.copyTo(out, 1 shl 20)
                    }
                } ?: throw IOException("无法复制到新文件")
            } catch (e: Exception) {
                runCatching { DocumentsContract.deleteDocument(resolver, target) }
                backupUri?.let { runCatching { DocumentsContract.renameDocument(resolver, it, name) } }
                throw e
            }
            runCatching { DocumentsContract.deleteDocument(resolver, partUri) }
            backupUri?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
            return target
        }

        // 5) 成功：清理备份
        backupUri?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
        return partUri
    }

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
    private fun saveToDownloads(name: String, source: File): String {
        val resolver = contentResolver
        if (Build.VERSION.SDK_INT >= 29) {
            val existing = findDownload(name)
            if (existing != null) {
                try {
                    resolver.openOutputStream(existing, "wt")?.use { out ->
                        source.inputStream().use { input -> input.copyTo(out, 1 shl 20) }
                    } ?: throw IOException("无法写入下载目录")
                    return "下载/MP4Fix/$name"
                } catch (e: Exception) {
                    // 覆盖失败：删掉旧文件后走下面的新建流程
                    runCatching { resolver.delete(existing, null, null) }
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/MP4Fix",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("无法在下载目录创建文件")
            try {
                resolver.openOutputStream(uri, "w")?.use { out ->
                    source.inputStream().use { input -> input.copyTo(out, 1 shl 20) }
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
            return "下载/MP4Fix/$name"
        }
        val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "MP4Fix")
        if (!dir.exists()) dir.mkdirs()
        val out = File(dir, name)
        source.inputStream().use { input ->
            out.outputStream().buffered(1 shl 20).use { o -> input.copyTo(o, 1 shl 20) }
        }
        return out.absolutePath
    }

    /** 在「下载/MP4Fix」里找同名文件（Android 10+）。 */
    private fun findDownload(name: String): Uri? {
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
                        return ContentUris.withAppendedId(collection, c.getLong(idCol))
                    }
                }
            } catch (e: Exception) {
                return null
            }
            return null
        }
        val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "MP4Fix")
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

    private fun copyToCache(uri: Uri, name: String): String {
        val dir = File(cacheDir, "imports").apply { mkdirs() }
        val safeName = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(120)
        val out = File(dir, "${System.nanoTime()}-$safeName")
        contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().buffered(1 shl 20).use { o -> input.copyTo(o, 1 shl 20) }
        } ?: throw IOException("无法读取 $uri")
        return out.absolutePath
    }

    companion object {
        private const val CHANNEL = "mp4fix/platform"
        private const val MAX_MOOV = 256L shl 20 // 预取 moov 上限 256MB
        private const val MAX_MOOF = 64L shl 20 // 单个 moof 上限 64MB
        private const val MAX_FRAGMENTS = 20000 // 预取 moof 个数上限
        private const val MAX_BOX_COUNT = 50000 // 盒扫描保护上限
    }
}
