package app.gather.gather

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Synchronized durable job records, separate from WorkManager's scheduling DB. */
object DownloadStore {
    private fun prefs(context: Context) = context.getSharedPreferences("gather", Context.MODE_PRIVATE)

    @Synchronized fun all(context: Context): List<JSONObject> {
        val array = JSONArray(prefs(context).getString("jobs", "[]"))
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    @Synchronized fun get(context: Context, id: String): JSONObject =
        all(context).firstOrNull { it.getString("id") == id }
            ?: throw IllegalArgumentException("Download record is missing")

    @Synchronized fun put(context: Context, record: JSONObject) {
        val records = all(context).toMutableList()
        val index = records.indexOfFirst { it.getString("id") == record.getString("id") }
        if (index >= 0) records[index] = record else records.add(0, record)
        // Keep active work; cap completed history to avoid unbounded preferences.
        val active = setOf("queued", "running", "retrying", "saving")
        var completed = 0
        val retained = records.filter { active.contains(it.optString("status")) || completed++ < 500 }
        check(prefs(context).edit().putString("jobs", JSONArray(retained).toString()).commit()) {
            "Could not persist download history"
        }
    }

    @Synchronized fun update(context: Context, id: String, vararg fields: Pair<String, Any>) {
        val record = get(context, id)
        fields.forEach { (key, value) -> record.put(key, value) }
        put(context, record)
    }

    fun settings(context: Context): Map<String, Any> {
        val p = prefs(context)
        return mapOf("wifiOnly" to p.getBoolean("wifiOnly", false),
            "darkMode" to (p.getString("darkMode", "system") ?: "system"),
            "folderUri" to (p.getString("folderUri", "") ?: ""),
            "folderName" to (p.getString("folderName", "Pictures/Gather · Movies/Gather") ?: "Pictures/Gather · Movies/Gather"),
            "accepted" to p.getBoolean("accepted", false))
    }

    fun setSettings(context: Context, values: Map<*, *>) {
        val edit = prefs(context).edit()
        values.forEach { (key, value) -> when (key) {
            "wifiOnly", "accepted" -> if (value is Boolean) edit.putBoolean(key as String, value)
            "darkMode", "folderUri", "folderName" -> if (value is String) edit.putString(key as String, value)
        } }
        check(edit.commit()) { "Could not save settings" }
    }

    fun toMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
        val value = json.get(key)
        if (value == JSONObject.NULL) null else value
    }
}
