package com.u707t.mp4fix

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

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

            "deleteDocument" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.error("bad_args", "缺少 uri", null)
                    return
                }
                runCatching { DocumentsContract.deleteDocument(contentResolver, uri) }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /// 在后台线程执行大文件 IO，结果回主线程（避免 ANR）。
    private fun runInBackground(
        result: MethodChannel.Result,
        block: () -> String,
    ) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
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

        // 1) 先写 .part
        val partUri = findChild(tree, parent, partName) ?: createDocument(tree, parent, partName)
        resolver.openOutputStream(partUri, "wt")?.use { out ->
            source.inputStream().use { input -> input.copyTo(out, 1 shl 20) }
        } ?: throw IOException("无法打开输出流（所选文件夹不可写）")

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
            val target = createDocument(tree, parent, name)
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
    }
}
