package com.example.kazumi

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Self-updates for the phone and television packages. */
class NakuTVUpdater(private val activity: Activity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val directory get() = File(activity.cacheDir, "naku-tv-updates")
    private val expectedPackage get() = activity.packageName
    private val prefix get() = if (expectedPackage == "com.nakutop.nakuplayer.tv") "naku-tv" else "naku-mobile"
    private val patches = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicBoolean>()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "naku/tv-updater").setMethodCallHandler { call, result ->
            if (expectedPackage !in setOf("com.nakutop.nakuplayer", "com.nakutop.nakuplayer.tv")) {
                result.error("INVALID_PACKAGE", "当前应用无法使用此更新源", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "state" -> {
                    val installed = packageInfo()
                    directory.mkdirs()
                    result.success(mapOf("package" to installed.packageName,
                        "version" to installed.versionName, "build" to versionCode(installed),
                        "directory" to directory.absolutePath, "canInstall" to canInstall()))
                }
                "baseHash" -> executor.execute {
                    try {
                        val file = File(activity.applicationInfo.sourceDir)
                        val digest = if (activity.applicationInfo.splitSourceDirs.isNullOrEmpty()) fileHash(file) else null
                        activity.runOnUiThread { result.success(digest) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { result.success(null) }
                    }
                }
                "applyDelta" -> {
                    val key = call.argument<String>("path").orEmpty()
                    val stop = java.util.concurrent.atomic.AtomicBoolean(false)
                    if (patches.putIfAbsent(key, stop) != null) {
                        result.error("BUSY", "此更新正在合成", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val output = updateFile(key)
                            val patch = File(output.path + ".gdiff.gz")
                            val size = call.argument<Number>("bytes")?.toLong() ?: 0
                            val baseBuild = call.argument<Number>("baseBuild")?.toLong()
                            require(baseBuild == versionCode(packageInfo()) && activity.applicationInfo.splitSourceDirs.isNullOrEmpty()) { "已安装版本不匹配" }
                            NakuApkDelta.apply(File(activity.applicationInfo.sourceDir), patch, output, size) { stop.get() }
                            activity.runOnUiThread { result.success(null) }
                        } catch (error: Exception) {
                            activity.runOnUiThread { result.error("DELTA_FAILED", error.message, null) }
                        } finally { patches.remove(key, stop) }
                    }
                }
                "cancelDelta" -> {
                    patches[call.argument<String>("path").orEmpty()]?.set(true)
                    result.success(null)
                }
                "permission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26 && !canInstall()) {
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}")))
                        }
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("PERMISSION_UNAVAILABLE", "请在系统设置中允许安装更新", null)
                    }
                }
                "verify", "install" -> executor.execute {
                    try {
                        val file = verify(call)
                        activity.runOnUiThread {
                            if (call.method == "verify") result.success(null)
                            else if (!canInstall()) result.success(false)
                            else try {
                                val uri = FileProvider.getUriForFile(activity,
                                    "${activity.packageName}.tvupdates", file)
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                activity.startActivity(intent)
                                result.success(true)
                            } catch (_: Exception) {
                                result.error("INSTALL_UNAVAILABLE", "无法打开系统安装器", null)
                            }
                        }
                    } catch (error: Exception) {
                        activity.runOnUiThread {
                            result.error("INVALID_UPDATE", error.message ?: "安装包验证失败", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() { patches.values.forEach { it.set(true) }; executor.shutdownNow() }
    private fun canInstall() = Build.VERSION.SDK_INT < 26 ||
        activity.packageManager.canRequestPackageInstalls()

    @Suppress("DEPRECATION")
    private fun packageInfo(): PackageInfo = activity.packageManager.getPackageInfo(
        activity.packageName, 0)

    @Suppress("DEPRECATION")
    private fun signatures(path: String? = null): Set<String> =
        NakuTVUpdateSignatures.read(Build.VERSION.SDK_INT >= 28) { modern ->
            val flags = if (modern) PackageManager.GET_SIGNING_CERTIFICATES
                else PackageManager.GET_SIGNATURES
            val info = if (path == null)
                activity.packageManager.getPackageInfo(activity.packageName, flags)
            else activity.packageManager.getPackageArchiveInfo(path, flags)
            val certificates = if (modern) info?.signingInfo?.apkContentsSigners
                else info?.signatures
            certificates?.map { it.toByteArray() }?.toTypedArray()
        }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun updateFile(path: String): File {
        val file = File(path).canonicalFile
        require(file.parentFile == directory.canonicalFile && file.name.matches(
            Regex("$prefix-[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+-[0-9]+\\.apk"))) { "安装包路径无效" }
        return file
    }

    private fun fileHash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    @Suppress("DEPRECATION")
    private fun verify(call: MethodCall): File {
        val path = call.argument<String>("path") ?: error("未找到安装包")
        val expectedHash = call.argument<String>("sha256") ?: error("缺少校验信息")
        require(expectedHash.matches(Regex("[0-9a-f]{64}"))) { "校验信息不正确" }
        val expectedBytes = call.argument<Number>("bytes")?.toLong() ?: 0
        val expectedBuild = call.argument<Number>("build")?.toLong() ?: 0
        val expectedVersion = call.argument<String>("version") ?: ""
        val file = updateFile(path)
        require(file.isFile && file.length() == expectedBytes &&
            expectedBytes in 1..(500L * 1024 * 1024)) { "安装包大小不正确" }
        require(fileHash(file) == expectedHash) { "安装包校验失败" }
        // Read metadata independently; certificate API failures must reach the
        // compatibility reader below rather than aborting this first query.
        val archive = activity.packageManager.getPackageArchiveInfo(file.path, 0)
            ?: error("安装包无法识别")
        val installed = packageInfo()
        require(archive.packageName == expectedPackage && archive.packageName == installed.packageName) {
            "安装包不是 NAKU TV"
        }
        require(versionCode(archive) == expectedBuild && versionCode(archive) > versionCode(installed) &&
            archive.versionName == expectedVersion) { "安装包版本不正确或不是新版本" }
        val currentSigners = signatures()
        val archiveSigners = signatures(file.path)
        require(currentSigners.isNotEmpty()) { "无法读取当前应用签名，请重试" }
        require(archiveSigners.isNotEmpty()) { "无法读取安装包签名，请重新下载" }
        require(archiveSigners == currentSigners) {
            "安装包签名与当前应用不一致"
        }
        return file
    }
}
