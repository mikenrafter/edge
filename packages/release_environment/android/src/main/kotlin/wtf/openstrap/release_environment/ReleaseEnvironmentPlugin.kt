package wtf.openstrap.release_environment

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Registered by Flutter in both the foreground and WorkManager engines. */
class ReleaseEnvironmentPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "openstrap/release_environment").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "storagePath" -> result.success(context.noBackupFilesDir.absolutePath)
                    "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "unmetered" -> {
                        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val caps = manager.getNetworkCapabilities(manager.activeNetwork)
                        result.success(caps != null &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) &&
                            !manager.isActiveNetworkMetered)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
