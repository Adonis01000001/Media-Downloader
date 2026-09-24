package app.gather.gather

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.documentfile.provider.DocumentFile
import androidx.work.*
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private var folderResult: MethodChannel.Result? = null
    private val shares = mutableListOf<String>()
    private val instagramAuthCallbacks = mutableListOf<String>()
    private val xAuthCallbacks = mutableListOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.gather/native")
        collectShare(intent)
        collectInstagramAuth(intent)
        collectXAuth(intent)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getState" -> executor.execute {
                        try {
                            val infos = WorkManager.getInstance(this).getWorkInfosByTag("gather").get()
                            val states = infos.associateBy { it.id.toString() }
                            val jobs = DownloadStore.all(this).map { record ->
                                val state = states[record.getString("id")]?.state
                                if (record.optString("status") != "complete") {
                                    when (state) {
                                        WorkInfo.State.CANCELLED -> record.put("status", "cancelled")
                                        WorkInfo.State.FAILED -> record.put("status", "failed")
                                        WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED -> record.put("status", "queued")
                                        else -> Unit
                                    }
                                }
                                DownloadStore.toMap(record)
                            }
                            runOnUiThread { result.success(mapOf("settings" to DownloadStore.settings(this), "jobs" to jobs)) }
                        } catch (e: Exception) { runOnUiThread { result.error("storage", e.message, null) } }
                    }
                    "takeShares" -> { result.success(shares.toList()); shares.clear() }
                    "takeInstagramAuthCallbacks" -> {
                        result.success(instagramAuthCallbacks.toList())
                        instagramAuthCallbacks.clear()
                    }
                    "readInstagramAuth" -> result.success(InstagramSecureStorage(this).read())
                    "writeInstagramAuth" -> {
                        val value = call.argument<String>("value") ?: throw IllegalArgumentException("Missing authorization state")
                        InstagramSecureStorage(this).write(value)
                        result.success(null)
                    }
                    "clearInstagramAuth" -> { InstagramSecureStorage(this).clear(); result.success(null) }
                    "takeProviderAuthCallbacks" -> {
                        require(call.argument<String>("provider") == "x") { "Unsupported OAuth provider" }
                        result.success(xAuthCallbacks.toList())
                        xAuthCallbacks.clear()
                    }
                    "readProviderAuth" -> {
                        val provider = call.argument<String>("provider") ?: throw IllegalArgumentException("Missing provider")
                        result.success(ProviderSecureStorage(this, provider).read())
                    }
                    "writeProviderAuth" -> {
                        val provider = call.argument<String>("provider") ?: throw IllegalArgumentException("Missing provider")
                        val value = call.argument<String>("value") ?: throw IllegalArgumentException("Missing authorization state")
                        ProviderSecureStorage(this, provider).write(value)
                        result.success(null)
                    }
                    "clearProviderAuth" -> {
                        val provider = call.argument<String>("provider") ?: throw IllegalArgumentException("Missing provider")
                        ProviderSecureStorage(this, provider).clear()
                        result.success(null)
                    }
                    "openProviderAuthorization" -> {
                        val provider = call.argument<String>("provider") ?: throw IllegalArgumentException("Missing provider")
                        require(provider == "x") { "Unsupported OAuth provider" }
                        val uri = Uri.parse(call.argument<String>("url"))
                        require(uri.scheme == "https" && uri.host == "x.com" && uri.path == "/i/oauth2/authorize") {
                            "Only X's official authorization page may be opened"
                        }
                        val scopes = uri.getQueryParameter("scope")?.split(Regex("[, ]+"))?.toSet() ?: emptySet()
                        require(uri.getQueryParameter("response_type") == "code" &&
                            uri.getQueryParameter("code_challenge_method") == "S256" &&
                            scopes.containsAll(setOf("tweet.read", "users.read", "offline.access"))) {
                            "The X authorization request is missing required read permissions or PKCE"
                        }
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    }
                    "openInstagramAuthorization" -> {
                        val uri = Uri.parse(call.argument<String>("url"))
                        require(uri.scheme == "https" && uri.host == "www.instagram.com" && uri.path == "/oauth/authorize") {
                            "Only Instagram's official authorization page may be opened"
                        }
                        require(uri.getQueryParameter("response_type") == "code" &&
                            uri.getQueryParameter("scope")?.split(Regex("[, ]+"))?.contains("instagram_business_basic") == true) {
                            "The Instagram authorization request is missing the required read scope"
                        }
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    }
                    "setSettings" -> { DownloadStore.setSettings(this, call.arguments as Map<*, *>); result.success(null) }
                    "chooseFolder" -> {
                        check(folderResult == null) { "A folder picker is already open" }
                        folderResult = result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }, 710)
                    }
                    "download" -> {
                        val args = call.arguments as Map<*, *>
                        executor.execute {
                            try {
                                val response = enqueue(args)
                                runOnUiThread { result.success(response) }
                            } catch (e: Exception) { runOnUiThread { result.error("download", e.message, null) } }
                        }
                    }
                    "notifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 711)
                        }
                        result.success(null)
                    }
                    "cancel" -> {
                        val jobId = call.argument<String>("id") ?: throw IllegalArgumentException("Missing job ID")
                        executor.execute {
                            try {
                                WorkManager.getInstance(this).cancelWorkById(UUID.fromString(jobId)).result.get()
                                if (DownloadStore.get(this, jobId).optString("status") != "complete") {
                                    DownloadStore.update(this, jobId, "status" to "cancelled")
                                }
                                runOnUiThread { result.success(null) }
                            } catch (e: Exception) { runOnUiThread { result.error("cancel", e.message, null) } }
                        }
                    }
                    "openFile" -> {
                        val uri = Uri.parse(call.argument<String>("uri"))
                        require(uri.scheme == "content") { "Only saved files may be opened" }
                        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, call.argument<String>("mime") ?: "*/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                        result.success(null)
                    }
                    "openSource" -> {
                        val uri = Uri.parse(call.argument<String>("url"))
                        require(DownloadWorker.validSource(uri.toString())) { "Unsupported source URL" }
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                if (call.method == "chooseFolder") folderResult = null
                result.error("android", e.message ?: "Android could not complete this action", null)
            }
        }
    }

    private fun collectShare(incoming: Intent?) {
        if (incoming?.action == Intent.ACTION_SEND && incoming.type == "text/plain") {
            incoming.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.length <= 20000 }?.let { shares.add(it) }
            incoming.removeExtra(Intent.EXTRA_TEXT)
        }
    }

    private fun collectInstagramAuth(incoming: Intent?) {
        val uri = incoming?.data ?: return
        if (incoming.action != Intent.ACTION_VIEW || uri.scheme != "gather" || uri.host != "instagram-auth") return
        if (!uri.path.isNullOrEmpty() || !uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) return
        if (instagramAuthCallbacks.size < 4) instagramAuthCallbacks.add(uri.toString())
    }

    private fun collectXAuth(incoming: Intent?) {
        val uri = incoming?.data ?: return
        if (incoming.action != Intent.ACTION_VIEW || uri.scheme != "gather" || uri.host != "x-auth") return
        if (!uri.path.isNullOrEmpty() || !uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) return
        if (xAuthCallbacks.size < 4) xAuthCallbacks.add(uri.toString())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        collectShare(intent)
        collectInstagramAuth(intent)
        collectXAuth(intent)
        if (::channel.isInitialized) channel.invokeMethod("sharesAvailable", null)
        if (instagramAuthCallbacks.isNotEmpty() && ::channel.isInitialized) {
            channel.invokeMethod("instagramAuthAvailable", null)
        }
        if (xAuthCallbacks.isNotEmpty() && ::channel.isInitialized) {
            channel.invokeMethod("xAuthAvailable", null)
        }
    }

    @Deprecated("Activity API required by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 710) return
        val result = folderResult ?: return
        folderResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(null); return }
        try {
            val uri = data.data!!
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            require(flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0) { "The selected folder did not grant write access" }
            contentResolver.takePersistableUriPermission(uri, flags)
            val folder = DocumentFile.fromTreeUri(this, uri)
            require(folder != null && folder.canWrite()) { "The selected folder is not writable" }
            val old = DownloadStore.settings(this)["folderUri"] as String
            DownloadStore.setSettings(this, mapOf("folderUri" to uri.toString(), "folderName" to (folder.name ?: "Selected folder")))
            // Old grants may still be used by an active queued job; retain until app uninstall.
            result.success(mapOf("folderUri" to uri.toString(), "folderName" to folder.name, "previousFolder" to old))
        } catch (e: Exception) { result.error("folder", e.message, null) }
    }

    private fun enqueue(args: Map<*, *>): Map<String, Any> {
        val url = args["url"] as String
        val source = args["source"] as String
        val platform = args["platform"] as String
        val type = args["type"] as String
        require(DownloadStore.settings(this)["accepted"] == true) { "Please acknowledge the personal-use notice first" }
        require(DownloadWorker.validMedia(url, platform) && DownloadWorker.validSource(source)) { "Unsupported source or media URL" }
        require(type == "image" || type == "video") { "Unsupported media type" }
        require(url.length <= 16000 && source.length <= 2000) { "The URL is too long" }
        val itemKey = args["itemKey"] as String
        val duplicate = DownloadStore.all(this).firstOrNull {
            it.optString("itemKey") == itemKey && (it.optString("status") == "complete" ||
                WorkManager.getInstance(this).getWorkInfoById(UUID.fromString(it.getString("id"))).get()?.state?.isFinished == false)
        }
        if (duplicate != null && args["force"] != true) return mapOf("duplicate" to true, "id" to duplicate.getString("id"))
        val settings = DownloadStore.settings(this)
        val work = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(if (settings["wifiOnly"] == true) NetworkType.UNMETERED else NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
            .addTag("gather")
            .build()
        val record = JSONObject().apply {
            put("id", work.id.toString()); put("url", url); put("source", source)
            put("platform", platform); put("type", type); put("itemKey", itemKey)
            put("name", (args["name"] as String).take(120)); put("thumbnail", args["thumbnail"] ?: "")
            put("status", "queued"); put("progress", 0); put("bytes", 0L)
            put("created", System.currentTimeMillis()); put("error", "")
            put("folderUri", settings["folderUri"]); put("wifiOnly", settings["wifiOnly"])
        }
        DownloadStore.put(this, record)
        try { WorkManager.getInstance(this).enqueueUniqueWork("gather-${work.id}", ExistingWorkPolicy.KEEP, work).result.get() }
        catch (e: Exception) {
            DownloadStore.update(this, work.id.toString(), "status" to "failed", "error" to "Could not schedule the download")
            throw e
        }
        return mapOf("duplicate" to false, "id" to work.id.toString())
    }

    override fun onDestroy() {
        folderResult?.error("cancelled", "The activity closed before folder selection completed", null)
        folderResult = null
        executor.shutdown()
        super.onDestroy()
    }
}
