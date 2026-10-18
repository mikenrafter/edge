package wtf.openstrap.openstrap_edge

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * App-owned notification listener for the band relay. It forwards routing
 * metadata only: category, package, a hash of the system key, post/remove time,
 * the interruption-filter match, current filter, ringer mode, ongoing/group
 * flags, channel importance and a readable vibration pattern. It never reads
 * what a notification says, and it never changes the user's Do Not Disturb
 * setting — the band policy lives in Dart and only decides whether to buzz.
 *
 * Events go to Dart only while an engine is cached (see EdgeApplication): a
 * cold-started, engine-less process drops them, and Dart pulls [activeMetadata]
 * when it comes up and on every reconnect, so nothing stale is replayed.
 */
class OpenStrapNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        NotificationRelayBridge.bind(this)
        NotificationRelayBridge.send("connected", activeMetadata())
    }

    override fun onListenerDisconnected() {
        NotificationRelayBridge.unbind(this)
        NotificationRelayBridge.send("disconnected", null)
    }

    override fun onDestroy() {
        // The service can die without onListenerDisconnected; clear the latch
        // here regardless so Dart never believes a dead listener is bound.
        try {
            NotificationRelayBridge.unbind(this)
            NotificationRelayBridge.send("destroyed", null)
        } finally {
            super.onDestroy()
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: NotificationListenerService.RankingMap) {
        if (NotificationRelayBridge.armed) {
            NotificationRelayBridge.send("metadata", metadata(sbn, "post", rankingMap))
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: NotificationListenerService.RankingMap) {
        if (NotificationRelayBridge.armed) {
            NotificationRelayBridge.send("metadata", metadata(sbn, "remove", rankingMap))
        }
    }

    fun activeMetadata(): List<Map<String, Any?>> = try {
        (activeNotifications ?: emptyArray()).map { metadata(it, "post", null) }
    } catch (_: SecurityException) {
        emptyList()
    }

    private fun metadata(
        sbn: StatusBarNotification,
        kind: String,
        rankingMap: NotificationListenerService.RankingMap?,
    ): Map<String, Any?> {
        val n = sbn.notification
        val ranking = NotificationListenerService.Ranking()
        val ranked = try {
            (rankingMap ?: currentRanking).getRanking(sbn.key, ranking)
        } catch (_: Exception) {
            false
        }
        val filter = try {
            currentInterruptionFilter
        } catch (_: SecurityException) {
            NotificationListenerService.INTERRUPTION_FILTER_UNKNOWN
        }
        val ringer = (getSystemService(Context.AUDIO_SERVICE) as AudioManager).ringerMode
        // Readable only when Android would actually vibrate for this post.
        val pattern: LongArray? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (ranked) ranking.channel?.takeIf { it.shouldVibrate() }?.vibrationPattern else null
            } else {
                n.vibrate
            }
        return mapOf(
            "category" to (n.category ?: ""),
            "package" to sbn.packageName,
            "keyHash" to hash(sbn.key),
            "kind" to kind,
            "postTimeMs" to sbn.postTime,
            "receiptTimeMs" to System.currentTimeMillis(),
            "matchesInterruptionFilter" to if (ranked) ranking.matchesInterruptionFilter() else null,
            "interruptionFilter" to filter,
            "ringerMode" to ringer,
            "ongoing" to sbn.isOngoing,
            "groupSummary" to ((n.flags and android.app.Notification.FLAG_GROUP_SUMMARY) != 0),
            "importance" to if (ranked) ranking.importance else null,
            "hapticPattern" to pattern?.toList(),
        )
    }

    private fun hash(key: String): String =
        MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
            .take(8).joinToString("") { "%02x".format(it) }
}

/** Dart <-> listener bridge. Registered on the shared engine by [NativeChannels]. */
object NotificationRelayBridge {
    private const val CHANNEL = "openstrap/notification_relay"

    /** Dart sets this only while the relay can act; false keeps metadata off the channel. */
    @Volatile var armed = false
    @Volatile var connected = false
    @Volatile private var listener: OpenStrapNotificationListener? = null
    private var channel: MethodChannel? = null

    fun bind(l: OpenStrapNotificationListener) {
        listener = l
        connected = true
    }

    fun unbind(l: OpenStrapNotificationListener) {
        if (listener === l) listener = null
        connected = false
    }

    /** Listener callbacks run on the main thread, which MethodChannel requires. */
    fun send(method: String, args: Any?) {
        channel?.invokeMethod(method, args)
    }

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPermissionGranted" -> result.success(permissionGranted(app))
                    "requestPermission" -> {
                        app.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "setArmed" -> {
                        armed = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    "isConnected" -> result.success(connected)
                    "activeMetadata" ->
                        result.success(if (armed) listener?.activeMetadata() ?: emptyList() else emptyList())
                    "rebind" -> {
                        try {
                            NotificationListenerService.requestRebind(
                                ComponentName(app, OpenStrapNotificationListener::class.java)
                            )
                        } catch (_: Exception) {
                            // Best effort: the system rebinds on its own schedule too.
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun permissionGranted(context: Context): Boolean =
        Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?.split(':')
            ?.any { ComponentName.unflattenFromString(it)?.packageName == context.packageName }
            ?: false
}
