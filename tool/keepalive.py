"""Writes the Kotlin keep-alive service and method channel into the generated Android project."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) / "android" / "app" / "src" / "main"
acts = list(root.rglob("MainActivity.kt"))
if not acts:
    print("MainActivity.kt not found", file=sys.stderr)
    sys.exit(1)
main = acts[0]
pkg = re.search(r"^package\s+([\w.]+)", main.read_text(), re.M).group(1)

MAIN = """package PKG

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omni/keepalive").setMethodCallHandler { call, result ->
            try {
                if (call.method == "start") {
                    if (Build.VERSION.SDK_INT >= 33) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                    }
                    val i = Intent(this, KeepAliveService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    result.success(null)
                } else if (call.method == "stop") {
                    stopService(Intent(this, KeepAliveService::class.java))
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("keepalive", e.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omni/termux").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isInstalled" -> result.success(TermuxBridge.isInstalled(this))
                    "hasPermission" -> result.success(TermuxBridge.hasPermission(this))
                    "diagnose" -> result.success(TermuxBridge.diagnose(this))
                    "requestPermission" -> {
                        if (TermuxBridge.hasPermission(this)) {
                            result.success(true)
                        } else {
                            TermuxBridge.pendingPermissionResult = result
                            requestPermissions(arrayOf(TermuxBridge.PERMISSION), TermuxBridge.PERMISSION_REQUEST_CODE)
                        }
                    }
                    "run" -> {
                        val command = call.argument<String>("command") ?: ""
                        val workdir = call.argument<String>("workdir")
                        val timeoutMs = (call.argument<Any>("timeoutMs") as? Number)?.toLong() ?: 60000L
                        TermuxBridge.run(this, command, workdir, timeoutMs, result)
                    }
                    "openAppSettings" -> {
                        // Android stops showing the runtime permission dialog after it has been denied enough
                        // times, with no further signal to the app — the only way back in is this settings page.
                        val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        i.data = Uri.fromParts("package", packageName, null)
                        startActivity(i)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("termux", e.message, null)
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == TermuxBridge.PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            TermuxBridge.pendingPermissionResult?.success(granted)
            TermuxBridge.pendingPermissionResult = null
        }
    }
}
"""

SERVICE = """package PKG

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class KeepAliveService : Service() {
    private var lock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "omni_work"
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channelId, "Background work", NotificationManager.IMPORTANCE_LOW))
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId) else Notification.Builder(this)
        val notification = builder
            .setContentTitle("Omni Chat is working")
            .setContentText("Finishing your task in the background")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(4711, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(4711, notification)
        }
        if (lock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omni:work").apply { acquire(60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        lock?.let { if (it.isHeld) it.release() }
        lock = null
        super.onDestroy()
    }
}
"""

TERMUX = """package PKG

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

// Talks to the separately installed Termux app over its own RUN_COMMAND intent API, so the assistant
// can run a real shell command on the user's device (see https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent).
// Requires: Termux installed, this app granted the RUN_COMMAND permission, and Termux's own
// ~/.termux/termux.properties set to allow-external-apps = true (only settable from inside Termux).
object TermuxBridge {
    private const val PACKAGE = "com.termux"
    private const val SERVICE = "com.termux.app.RunCommandService"
    private const val ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND"
    const val PERMISSION = "com.termux.permission.RUN_COMMAND"
    const val PERMISSION_REQUEST_CODE = 812

    private var nextRequestCode = 9000
    private val pending = HashMap<Int, MethodChannel.Result>()
    private var receiverRegistered = false
    var pendingPermissionResult: MethodChannel.Result? = null

    fun isInstalled(context: Context): Boolean = try {
        context.packageManager.getPackageInfo(PACKAGE, 0)
        true
    } catch (e: Exception) {
        false
    }

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, PERMISSION) == PackageManager.PERMISSION_GRANTED

    // Distinguishes "not granted yet" from "this exact Termux build cannot support RUN_COMMAND at all" —
    // some very old builds (long unmaintained, e.g. stuck on Google Play before it was delisted there)
    // predate RUN_COMMAND entirely, so they never declare its permission or service no matter how many
    // times the user grants or re-grants anything. In that case the terminal itself can work fine for
    // the person by hand while still never being reachable from this app.
    fun diagnose(context: Context): Map<String, Any> {
        val installed = isInstalled(context)
        var versionName = ""
        var versionCode = 0L
        if (installed) {
            try {
                val info = context.packageManager.getPackageInfo(PACKAGE, 0)
                versionName = info.versionName ?: ""
                versionCode = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            } catch (e: Exception) {
            }
        }
        val permissionDeclared = try {
            context.packageManager.getPermissionInfo(PERMISSION, 0)
            true
        } catch (e: Exception) {
            false
        }
        val serviceExists = try {
            context.packageManager.getServiceInfo(android.content.ComponentName(PACKAGE, SERVICE), 0)
            true
        } catch (e: Exception) {
            false
        }
        return mapOf(
            "installed" to installed,
            "versionName" to versionName,
            "versionCode" to versionCode,
            "permissionDeclared" to permissionDeclared,
            "serviceExists" to serviceExists,
            "hasPermission" to hasPermission(context),
            "supportsAutomation" to (permissionDeclared && serviceExists)
        )
    }

    // Registered once per process on the application context (not the activity), so it keeps working
    // across activity recreation (rotation, the system recreating the activity, ...) instead of being
    // tied to an activity instance that can be destroyed while a command is still running.
    private fun ensureReceiver(context: Context) {
        if (receiverRegistered) return
        receiverRegistered = true
        val appCtx = context.applicationContext
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val code = intent.getIntExtra("request_code", -1)
                val result = pending.remove(code) ?: return
                val bundle = intent.getBundleExtra("result")
                if (bundle == null) {
                    result.success(mapOf("stdout" to "", "stderr" to "", "exitCode" to -1, "err" to 1, "errmsg" to "No result from Termux."))
                    return
                }
                result.success(
                    mapOf(
                        "stdout" to (bundle.getString("stdout") ?: ""),
                        "stderr" to (bundle.getString("stderr") ?: ""),
                        "exitCode" to bundle.getInt("exitCode", -1),
                        "err" to bundle.getInt("err", 0),
                        "errmsg" to (bundle.getString("errmsg") ?: "")
                    )
                )
            }
        }
        val filter = IntentFilter(appCtx.packageName + ".TERMUX_RESULT")
        if (Build.VERSION.SDK_INT >= 33) {
            appCtx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appCtx.registerReceiver(receiver, filter)
        }
    }

    fun run(context: Context, command: String, workdir: String?, timeoutMs: Long, result: MethodChannel.Result) {
        if (!isInstalled(context)) {
            result.error("not_installed", "Termux is not installed", null)
            return
        }
        if (!hasPermission(context)) {
            result.error("no_permission", "RUN_COMMAND permission not granted", null)
            return
        }
        val appCtx = context.applicationContext
        ensureReceiver(appCtx)
        val code = nextRequestCode++
        pending[code] = result

        val resultIntent = Intent(appCtx.packageName + ".TERMUX_RESULT").setPackage(appCtx.packageName)
        resultIntent.putExtra("request_code", code)
        val piFlags = (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0) or PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getBroadcast(appCtx, code, resultIntent, piFlags)

        val intent = Intent()
        intent.setClassName(PACKAGE, SERVICE)
        intent.action = ACTION_RUN_COMMAND
        intent.putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
        intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-lc", command))
        if (!workdir.isNullOrBlank()) intent.putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir)
        intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
        intent.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pi)
        try {
            appCtx.startService(intent)
        } catch (e: Exception) {
            pending.remove(code)
            result.error("start_failed", "Could not start Termux: " + e.message, null)
            return
        }
        Handler(Looper.getMainLooper()).postDelayed({
            val r = pending.remove(code)
            r?.error("timeout", "Termux command timed out", null)
        }, timeoutMs)
    }
}
"""

main.write_text(MAIN.replace("PKG", pkg))
(main.parent / "KeepAliveService.kt").write_text(SERVICE.replace("PKG", pkg))
(main.parent / "TermuxBridge.kt").write_text(TERMUX.replace("PKG", pkg))
print("keep-alive service and Termux bridge written to", main.parent, "package", pkg)
