package app.gather.gather

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.work.ForegroundInfo
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

class DownloadWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    private val ctx = applicationContext
    private val jobId = id.toString()
    private val notificationId = id.hashCode() and 0x7fffffff
    private val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var connection: HttpURLConnection? = null

    companion object {
        private val saveLock = Any()
        private val domains = mapOf("x" to listOf("twimg.com"), "instagram" to listOf("cdninstagram.com", "fbcdn.net"), "pinterest" to listOf("pinimg.com"))
        fun validMedia(value: String, platform: String): Boolean {
            val uri = Uri.parse(value)
            val host = uri.host ?: return false
            return uri.scheme == "https" && uri.userInfo == null && (uri.port == -1 || uri.port == 443) &&
                domains[platform]?.any { host == it || host.endsWith(".$it") } == true
        }
        fun validSource(value: String): Boolean {
            val uri = Uri.parse(value)
            if (uri.scheme != "https" || uri.userInfo != null || (uri.port != -1 && uri.port != 443)) return false
            return when (uri.host) {
                "x.com", "www.x.com", "twitter.com", "www.twitter.com" -> Regex("/(?:[A-Za-z0-9_]+/status|i/web/status)/[0-9]+(?:/.*)?").matches(uri.path ?: "")
                "www.instagram.com", "instagram.com" -> Regex("/(?:p|reel|reels|tv)/[A-Za-z0-9_-]+/?").matches(uri.path ?: "")
                "www.pinterest.com", "pinterest.com" -> Regex("/pin/[0-9]+/?").matches(uri.path ?: "")
                "www.tiktok.com", "tiktok.com", "m.tiktok.com" -> Regex("/@[A-Za-z0-9._-]+/video/[0-9]+/?").matches(uri.path ?: "")
                else -> false
            }
        }
    }

    private class Permanent(message: String) : Exception(message)
    private class WaitingForWifi : IOException("Waiting for Wi-Fi")

    override fun doWork(): Result {
        val temp = File(ctx.cacheDir, "gather-$jobId.part")
        var destination: Uri? = null
        try {
            val job = DownloadStore.get(ctx, jobId)
            if (job.optString("status") == "complete") return Result.success()
            val stale = job.optString("pendingUri")
            if (stale.isNotEmpty()) {
                ctx.contentResolver.delete(Uri.parse(stale), null, null)
                DownloadStore.update(ctx, jobId, "pendingUri" to "")
            }
            if (!validMedia(job.getString("url"), job.getString("platform"))) throw Permanent("Unsupported media source")
            ensureWifi(job.optBoolean("wifiOnly"))
            manager.createNotificationChannel(NotificationChannel("downloads", "Downloads", NotificationManager.IMPORTANCE_LOW))
            manager.createNotificationChannel(NotificationChannel("completed", "Download results", NotificationManager.IMPORTANCE_DEFAULT))
            setForegroundAsync(foreground(job.getString("name"), 0)).get()
            DownloadStore.update(ctx, jobId, "status" to "running", "error" to "", "progress" to 0)
            var current = job.getString("url")
            var response: HttpURLConnection? = null
            for (redirect in 0..5) {
                if (!validMedia(current, job.getString("platform"))) throw Permanent("Media redirected outside the platform's CDN")
                val c = URL(current).openConnection() as HttpURLConnection
                connection = c
                c.instanceFollowRedirects = false
                c.connectTimeout = 20000; c.readTimeout = 30000
                c.setRequestProperty("User-Agent", "Gather/1.0 Android")
                c.setRequestProperty("Accept-Encoding", "identity")
                val status = c.responseCode
                if (status in listOf(301,302,303,307,308)) {
                    val target = c.getHeaderField("Location") ?: throw Permanent("Invalid media redirect")
                    current = URL(URL(current), target).toString()
                    c.disconnect()
                    continue
                }
                if (status == 429 || status in 500..599) throw IOException("Platform busy (HTTP $status)")
                if (status in listOf(401,403,404,410)) throw Permanent("Media is unavailable or its link expired. Re-fetch the public post.")
                if (status != 200) throw Permanent("The media server returned HTTP $status")
                response = c
                break
            }
            val c = response ?: throw Permanent("Too many media redirects")
            val total = c.contentLengthLong
            if (total > 2L * 1024 * 1024 * 1024) throw Permanent("This file exceeds the 2 GB per-file limit")
            var received = 0L
            var lastUpdate = 0L
            c.inputStream.use { input ->
                temp.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        if (isStopped) throw InterruptedIOException("Download cancelled")
                        val count = input.read(buffer)
                        if (count < 0) break
                        received += count
                        if (received > 2L * 1024 * 1024 * 1024) throw Permanent("This file exceeds the 2 GB per-file limit")
                        output.write(buffer, 0, count)
                        val now = System.currentTimeMillis()
                        if (now - lastUpdate > 750) {
                            ensureWifi(job.optBoolean("wifiOnly"))
                            val progress = if (total > 0) ((received * 100 / total).coerceAtMost(99)).toInt() else -1
                            DownloadStore.update(ctx, jobId, "bytes" to received, "total" to total, "progress" to progress)
                            manager.notify(notificationId, foreground(job.getString("name"), progress).notification)
                            lastUpdate = now
                        }
                    }
                    output.fd.sync()
                }
            }
            if (received == 0L || (total >= 0 && received != total)) throw IOException("The media download was incomplete")
            val mime = sniff(temp, job.getString("type"))
            val extension = when (mime) { "video/mp4" -> "mp4"; "image/png" -> "png"; "image/webp" -> "webp"; "image/gif" -> "gif"; else -> "jpg" }
            val base = safeBase(job.optString("name"), "gather")
            val desiredName = base.replace(Regex("(?i)\\.(jpg|jpeg|png|webp|gif|mp4)$"), "") + ".$extension"
            val downloadedAt = System.currentTimeMillis()
            if (isStopped) throw InterruptedIOException("Download cancelled")
            val folderUri = job.optString("folderUri")
            val allocated = synchronized(saveLock) {
                if (folderUri.isEmpty()) {
                    allocateMediaStore(mime, job.getString("type"), desiredName, downloadedAt)
                } else {
                    allocateSaf(folderUri, mime, desiredName)
                }
            }
            destination = allocated.uri
            val name = allocated.name
            DownloadStore.update(ctx, jobId, "status" to "saving", "name" to name, "downloadedAt" to downloadedAt)
            DownloadStore.update(ctx, jobId, "pendingUri" to destination.toString())
            val digest = MessageDigest.getInstance("SHA-256")
            val output = ctx.contentResolver.openOutputStream(destination, "w") ?: throw Permanent("The save folder refused write access")
            output.use { target -> temp.inputStream().use { input ->
                val buffer = ByteArray(65536)
                while (true) {
                    if (isStopped) throw InterruptedIOException("Download cancelled while saving")
                    val count = input.read(buffer)
                    if (count < 0) break
                    target.write(buffer, 0, count); digest.update(buffer, 0, count)
                }
                target.flush()
            } }
            if (folderUri.isEmpty()) {
                val values = mediaDateValues(downloadedAt).apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                check(ctx.contentResolver.update(destination, values, null, null) == 1) { "Could not publish the saved file" }
            } else {
                markSafDate(destination, mime, downloadedAt)
            }
            DownloadStore.update(ctx, jobId, "status" to "complete", "progress" to 100, "bytes" to received,
                "uri" to destination.toString(), "mime" to mime, "pendingUri" to "", "error" to "",
                "downloadedAt" to downloadedAt,
                "sha256" to digest.digest().joinToString("") { "%02x".format(it) })
            notifyResult(name, "Saved to ${if (folderUri.isEmpty()) "your device Gallery" else "your selected folder"}", destination, mime)
            return Result.success()
        } catch (e: Exception) {
            var cleanupError = ""
            if (destination != null) {
                try { ctx.contentResolver.delete(destination, null, null) }
                catch (cleanup: Exception) { cleanupError = " A partial file could not be removed: ${cleanup.message}" }
            }
            val retry = !isStopped && e is IOException && e !is java.io.FileNotFoundException &&
                (e is WaitingForWifi || runAttemptCount < 3) && cleanupError.isEmpty()
            val message = (e.message ?: e.javaClass.simpleName) + cleanupError
            DownloadStore.update(ctx, jobId, "status" to if (isStopped) "cancelled" else if (retry) "retrying" else "failed", "error" to message)
            if (!retry && !isStopped) notifyResult("Download could not finish", message, null, null)
            return if (retry) Result.retry() else Result.failure()
        } finally {
            connection?.disconnect()
            if (temp.exists() && !temp.delete()) android.util.Log.w("Gather", "Could not remove temporary download $jobId")
        }
    }

    private data class Allocation(val uri: Uri, val name: String)

    private fun safeBase(value: String, fallback: String): String {
        var cleaned = value
            .replace(Regex("[\\u0000-\\u001F<>:\"/\\\\|?*]"), "_")
            .replace(Regex("\\s+"), " ")
            .trim(' ', '.')
            .take(120)
            .trim(' ', '.')
        if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") cleaned = fallback
        if (Regex("(?i)^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$").matches(cleaned)) cleaned = "_$cleaned"
        return cleaned
    }

    private fun uniqueName(desired: String, exists: (String) -> Boolean): String {
        if (!exists(desired)) return desired
        val dot = desired.lastIndexOf('.')
        val stem = if (dot > 0) desired.substring(0, dot) else desired
        val extension = if (dot > 0) desired.substring(dot) else ""
        var suffix = 2
        while (suffix < 10000) {
            val candidate = "$stem ($suffix)$extension"
            if (!exists(candidate)) return candidate
            suffix++
        }
        return "$stem (${System.currentTimeMillis()})$extension"
    }

    private fun mediaDateValues(downloadedAt: Long): ContentValues = ContentValues().apply {
        put(MediaStore.MediaColumns.DATE_ADDED, downloadedAt / 1000L)
        put(MediaStore.MediaColumns.DATE_MODIFIED, downloadedAt / 1000L)
        put(MediaStore.MediaColumns.DATE_TAKEN, downloadedAt)
    }

    private fun allocateMediaStore(mime: String, type: String, desired: String, downloadedAt: Long): Allocation {
        val collection = if (type == "image") MediaStore.Images.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val relative = if (type == "image") Environment.DIRECTORY_PICTURES + "/Gather/" else Environment.DIRECTORY_MOVIES + "/Gather/"
        val name = uniqueName(desired) { mediaStoreContains(collection, relative, it) }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            putAll(mediaDateValues(downloadedAt))
        }
        val uri = ctx.contentResolver.insert(collection, values)
            ?: throw Permanent("Android could not create the Gallery media entry")
        return Allocation(uri, name)
    }

    private fun mediaStoreContains(collection: Uri, relative: String, name: String): Boolean {
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        return ctx.contentResolver.query(collection, projection, selection, arrayOf(name, relative), null)?.use { it.moveToFirst() } == true
    }

    private fun allocateSaf(folderUri: String, mime: String, desired: String): Allocation {
        val folder = DocumentFile.fromTreeUri(ctx, Uri.parse(folderUri))
        if (folder == null || !folder.canWrite()) throw Permanent("Folder access was lost. Choose the save folder again in Settings.")
        val name = uniqueName(desired) { folder.findFile(it) != null }
        val uri = folder.createFile(mime, name)?.uri ?: throw Permanent("Could not create a file in the selected folder")
        return Allocation(uri, name)
    }

    private fun markSafDate(uri: Uri, mime: String, downloadedAt: Long) {
        try {
            ctx.contentResolver.update(uri, ContentValues().apply {
                put(DocumentsContract.Document.COLUMN_LAST_MODIFIED, downloadedAt)
            }, null, null)
        } catch (e: Exception) {
            android.util.Log.w("Gather", "Selected folder provider did not accept the download timestamp", e)
        }
        val path = when {
            uri.scheme == "file" -> uri.path
            uri.authority == "com.android.externalstorage.documents" -> runCatching {
                val documentId = DocumentsContract.getDocumentId(uri)
                val parts = documentId.split(":", limit = 2)
                if (parts.size == 2 && parts[0] == "primary") {
                    File(Environment.getExternalStorageDirectory(), parts[1]).path
                } else {
                    null
                }
            }.getOrNull()
            else -> null
        }
        path?.let { MediaScannerConnection.scanFile(ctx, arrayOf(it), arrayOf(mime), null) }
    }

    private fun ensureWifi(required: Boolean) {
        if (!required) return
        val connectivity = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) throw WaitingForWifi()
    }

    private fun sniff(file: File, type: String): String {
        val header = ByteArray(32)
        val count = file.inputStream().use { it.read(header) }
        if (count < 12) throw Permanent("The server did not return a valid media file")
        val ascii = String(header, Charsets.ISO_8859_1)
        val mime = when {
            header[0] == 0xff.toByte() && header[1] == 0xd8.toByte() && header[2] == 0xff.toByte() -> "image/jpeg"
            header[0] == 0x89.toByte() && ascii.substring(1,4) == "PNG" -> "image/png"
            ascii.startsWith("GIF87a") || ascii.startsWith("GIF89a") -> "image/gif"
            ascii.startsWith("RIFF") && ascii.substring(8,12) == "WEBP" -> "image/webp"
            ascii.substring(4,8) == "ftyp" -> "video/mp4"
            else -> throw Permanent("The server returned unsupported content instead of an image or MP4")
        }
        if (!mime.startsWith("$type/")) throw Permanent("The media type does not match the selected item")
        return mime
    }

    private fun foreground(name: String, progress: Int): ForegroundInfo {
        val launch = PendingIntent.getActivity(ctx, notificationId, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(ctx, "downloads").setSmallIcon(R.drawable.ic_download)
            .setContentTitle("Saving $name").setContentText(if (progress < 0) "Downloading…" else "$progress%")
            .setOngoing(true).setOnlyAlertOnce(true).setProgress(100, progress.coerceAtLeast(0), progress < 0)
            .setContentIntent(launch).build()
        return ForegroundInfo(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    private fun notifyResult(title: String, text: String, uri: Uri?, mime: String?) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val intent = if (uri == null) Intent(ctx, MainActivity::class.java) else Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val pending = PendingIntent.getActivity(ctx, notificationId + 1, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(ctx, "completed").setSmallIcon(R.drawable.ic_download)
            .setContentTitle(title).setContentText(text).setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true).setContentIntent(pending).build()
        try { manager.notify(notificationId xor 0x40000000, notification) }
        catch (e: SecurityException) {
            // Notification permission may be revoked between the check and notify.
            // The persisted job/file result must remain authoritative.
            android.util.Log.w("Gather", "Completion notification permission was revoked", e)
        }
    }

    override fun onStopped() { connection?.disconnect(); super.onStopped() }
}
