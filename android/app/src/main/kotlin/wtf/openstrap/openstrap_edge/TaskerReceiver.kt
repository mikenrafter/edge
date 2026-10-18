package wtf.openstrap.openstrap_edge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/*
 * Device test checklist (none of this can run in CI; do it on a phone with
 * Tasker, the band connected, and Settings -> Automation -> "Tasker
 * connection" ON). Every intent below needs Package =
 * wtf.openstrap.openstrap_edge and the String extra token from
 * Settings -> Automation.
 *
 *  1. BUZZ_STRAP, extra pattern=1: the band buzzes once. Without the token,
 *     or without the Package, nothing happens (logcat tag TaskerReceiver says
 *     "rejected").
 *  2. PLAY_HAPTIC, slot=3 (Tasker's Int or Str): the band plays three short
 *     pulses. slot=1..6 each play that many pulses.
 *  3. PLAY_HAPTIC, slot=tasker.2: two pulses. slot=breath.done and
 *     slot=alert.water play those slots' patterns.
 *  4. PLAY_HAPTIC, pattern=sys.preset.sos: the SOS preset plays. A pattern id
 *     saved in the app's Haptics screen plays too.
 *  5. PLAY_HAPTIC, slot=7 or pattern=nope: nothing plays; the app log has a
 *     "[tasker] ignored" line.
 *  6. Put another pattern on Tasker slot 2 (Haptics -> Tasker) and repeat 2.
 *  7. Turn "Tasker connection" OFF and repeat 1 and 2: nothing plays. Gesture
 *     tab: the Broadcast to Tasker switch is dimmed with "Turn on Tasker
 *     first".
 *  8. Send two PLAY_HAPTIC intents less than 1.5 s apart: the second is
 *     dropped ("rate-limited"). Spend the band's command window (many plays):
 *     later plays wait, they do not cut in.
 *  9. Force-stop the app (engine dead) and send PLAY_HAPTIC: nothing plays,
 *     logcat says "engine dead, dropping". (BUZZ_STRAP still persists its
 *     pending flag, as before.)
 * 10. Map Broadcast to Tasker to the double AND the triple tap. A Tasker
 *     "Intent Received" profile on wtf.openstrap.openstrap_edge.DOUBLE_TAP
 *     sees slot=double / taps=2 for one, slot=triple / taps=3 for the other.
 */
class TaskerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.i(TAG, "onReceive: action=$action")
        if (action != ACTION_BUZZ_STRAP && action != ACTION_PLAY_HAPTIC) return

        // The token rides as a plain intent extra. If Tasker (or anything
        // else) sends this as an IMPLICIT broadcast (no setPackage/
        // setComponent), Android delivers it to every app on the device with
        // a matching action intent-filter — including a hostile one that
        // declares the same action just to eavesdrop on the extras. That app
        // could then replay the captured token straight at us later. Require
        // the delivered intent to have been explicitly targeted at this app
        // (our Settings → Automation copy already instructs "set Package to
        // wtf.openstrap.openstrap_edge") BEFORE even looking at the token.
        if (intent.`package` != context.packageName &&
            intent.component?.packageName != context.packageName
        ) {
            Log.w(TAG, "rejected: not explicitly targeted at this app")
            return
        }

        // This receiver is exported with no manifest permission (a signature
        // permission would block Tasker itself, since it isn't signed by us) —
        // so anyone who can send an explicitly-targeted broadcast can still
        // reach it. Require a per-install shared secret the user copies from
        // Settings → Automation into their Tasker action, plus a short rate
        // limit as defense in depth. See NativeChannels.getOrCreateTaskerToken.
        val expected = NativeChannels.getOrCreateTaskerToken(context)
        val provided = intent.getStringExtra(EXTRA_TOKEN)
        if (provided == null || provided != expected) {
            Log.w(TAG, "rejected: missing/incorrect token")
            return
        }

        val nowElapsed = SystemClock.elapsedRealtime()
        if (nowElapsed - lastAcceptedElapsedMs < MIN_INTERVAL_MS) {
            Log.w(TAG, "rejected: rate-limited (< ${MIN_INTERVAL_MS}ms since last accepted broadcast)")
            return
        }
        lastAcceptedElapsedMs = nowElapsed

        val engine = FlutterEngineCache.getInstance()
            .get(EdgeApplication.ENGINE_ID)

        if (action == ACTION_PLAY_HAPTIC) {
            playHaptic(intent, engine)
            return
        }

        val pattern = intent.getIntExtra(EXTRA_PATTERN, DEFAULT_PATTERN)
        Log.i(TAG, "pattern=$pattern")

        if (engine != null) {
            Log.i(TAG, "engine alive, invoking method channel")
            val args = java.util.HashMap<String, Any>()
            args["pattern"] = pattern
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                NativeChannels.TASKER_CHANNEL
            ).invokeMethod("buzz_strap", args)
            return
        }

        Log.i(TAG, "engine dead, persisting pending flag")
        val prefs = context.getSharedPreferences(
            "openstrap_runtime",
            Context.MODE_PRIVATE
        )
        prefs.edit()
            .putBoolean(PENDING_BUZZ_KEY, true)
            .putInt(PENDING_PATTERN_KEY, pattern)
            .apply()

        EdgeTrackingService.start(context)
    }

    /**
     * PLAY_HAPTIC: forward `slot` (an Int 1..6, or a String: a number or a slot
     * key) or `pattern` (a String id) to Dart as `tasker_play`; Dart decides
     * whether it is known, whether the Tasker connection is on and when the
     * band can take it. Dropped, not persisted, when the engine is dead.
     */
    private fun playHaptic(intent: Intent, engine: io.flutter.embedding.engine.FlutterEngine?) {
        if (engine == null) {
            Log.w(TAG, "engine dead, dropping PLAY_HAPTIC")
            return
        }
        val args = java.util.HashMap<String, Any>()
        // Tasker may send a number as an Int or as text; pass either through.
        val extras = intent.extras
        extras?.get(EXTRA_SLOT)?.let { if (it is Int || it is String) args["slot"] = it }
        if (!args.containsKey("slot")) {
            intent.getStringExtra(EXTRA_PATTERN_ID)?.let { args["pattern"] = it }
        }
        if (args.isEmpty()) {
            Log.w(TAG, "PLAY_HAPTIC without a slot or pattern")
            return
        }
        Log.i(TAG, "PLAY_HAPTIC $args")
        MethodChannel(engine.dartExecutor.binaryMessenger, NativeChannels.TASKER_CHANNEL)
            .invokeMethod("tasker_play", args)
    }

    companion object {
        const val TAG = "TaskerReceiver"
        const val ACTION_BUZZ_STRAP =
            "wtf.openstrap.openstrap_edge.BUZZ_STRAP"
        const val ACTION_PLAY_HAPTIC =
            "wtf.openstrap.openstrap_edge.PLAY_HAPTIC"
        const val EXTRA_PATTERN = "pattern"
        // PLAY_HAPTIC: `slot` (Int or String) or `pattern` (String id).
        const val EXTRA_SLOT = "slot"
        const val EXTRA_PATTERN_ID = "pattern"
        const val EXTRA_TOKEN = "token"
        const val PENDING_BUZZ_KEY = "pending_tasker_buzz"
        const val PENDING_PATTERN_KEY = "pending_tasker_buzz_pattern"
        const val DEFAULT_PATTERN = 2
        private const val MIN_INTERVAL_MS = 1500L

        // Process-lifetime, not persisted — a fresh process restarting the
        // rate-limit window on cold start is fine; the goal is only to blunt a
        // tight resend loop within one running process.
        @Volatile
        private var lastAcceptedElapsedMs = 0L
    }
}
