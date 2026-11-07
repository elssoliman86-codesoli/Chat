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
import android.os.Build
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

// Executes user-approved commands through Termux RUN_COMMAND. Termux remains a real device shell.
object TermuxBridge {
    private const val PACKAGE = "com.termux"
    private const val SERVICE = "com.termux.app.RunCommandService"
    private const val ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND"
    private const val BASH = "/data/data/com.termux/files/usr/bin/bash"
    private const val TIMEOUT = "/data/data/com.termux/files/usr/bin/timeout"
    const val PERMISSION = "com.termux.permission.RUN_COMMAND"
    const val PERMISSION_REQUEST_CODE = 812

    private var nextRequestCode = 9000
    private val pending = HashMap<Int, MethodChannel.Result>()
    private val timeoutCallbacks = HashMap<Int, Runnable>()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var receiverRegistered = false
    var pendingPermissionResult: MethodChannel.Result? = null

    fun isInstalled(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= 33) {
            context.packageManager.getPackageInfo(PACKAGE, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(PACKAGE, 0)
        }
        true
    } catch (_: Exception) {
        false
    }

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, PERMISSION) == PackageManager.PERMISSION_GRANTED

    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\\\\''") + "'"

    @Synchronized
    private fun ensureReceiver(context: Context) {
        if (receiverRegistered) return
        val appContext = context.applicationContext
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val code = intent.getIntExtra("request_code", -1)
                val result = pending.remove(code) ?: return
                timeoutCallbacks.remove(code)?.let { mainHandler.removeCallbacks(it) }
                val bundle = intent.getBundleExtra("result")
                if (bundle == null) {
                    result.success(mapOf("stdout" to "", "stderr" to "", "exitCode" to -1,
                        "errmsg" to "Termux returned no result bundle.", "err" to -1))
                    return
                }
                result.success(mapOf(
                    "stdout" to (bundle.getString("stdout") ?: ""),
                    "stderr" to (bundle.getString("stderr") ?: ""),
                    "exitCode" to bundle.getInt("exitCode", -1),
                    "errmsg" to (bundle.getString("errmsg") ?: ""),
                    "err" to bundle.getInt("err", 0)
                ))
            }
        }
        val filter = IntentFilter(appContext.packageName + ".TERMUX_RESULT")
        if (Build.VERSION.SDK_INT >= 33) {
            appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    fun run(context: Context, command: String, workdir: String?, timeoutMs: Long, result: MethodChannel.Result) {
        if (command.isBlank()) {
            result.error("invalid_command", "Command cannot be empty.", null)
            return
        }
        if (command.toByteArray(Charsets.UTF_8).size > 128 * 1024) {
            result.error("command_too_large", "Command exceeds the Termux RUN_COMMAND 128 KB limit.", null)
            return
        }
        if (!isInstalled(context)) {
            result.error("not_installed", "Termux is not installed.", null)
            return
        }
        if (!hasPermission(context)) {
            result.error("no_permission", "Grant the Run commands in Termux environment permission in Android settings.", null)
            return
        }

        val appContext = context.applicationContext
        ensureReceiver(appContext)
        val code = nextRequestCode++
        pending[code] = result

        val safeTimeoutMs = timeoutMs.coerceIn(1_000L, 300_000L)
        val timeoutSeconds = ((safeTimeoutMs + 999L) / 1_000L).coerceIn(1L, 300L)
        val wrappedCommand = "$TIMEOUT --signal=TERM --kill-after=5s ${timeoutSeconds}s $BASH -lc ${shellQuote(command)}"

        val resultIntent = Intent(appContext.packageName + ".TERMUX_RESULT").setPackage(appContext.packageName)
        resultIntent.putExtra("request_code", code)
        val mutableFlag = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val piFlags = mutableFlag or PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getBroadcast(appContext, code, resultIntent, piFlags)

        val intent = Intent(ACTION_RUN_COMMAND).apply {
            setClassName(PACKAGE, SERVICE)
            putExtra("com.termux.RUN_COMMAND_PATH", BASH)
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-lc", wrappedCommand))
            if (!workdir.isNullOrBlank()) putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pi)
        }

        val timeoutCallback = Runnable {
            val pendingResult = pending.remove(code)
            timeoutCallbacks.remove(code)
            pendingResult?.error("timeout", "Termux command exceeded the ${timeoutSeconds}s execution limit.", null)
        }
        timeoutCallbacks[code] = timeoutCallback
        mainHandler.postDelayed(timeoutCallback, safeTimeoutMs + 10_000L)

        try {
            appContext.startService(intent)
        } catch (e: Exception) {
            pending.remove(code)
            timeoutCallbacks.remove(code)?.let { mainHandler.removeCallbacks(it) }
            result.error("start_failed", "Could not start Termux: " + (e.message ?: e.toString()), null)
        }
    }
}
"""

main.write_text(MAIN.replace("PKG", pkg))
(main.parent / "KeepAliveService.kt").write_text(SERVICE.replace("PKG", pkg))
(main.parent / "TermuxBridge.kt").write_text(TERMUX.replace("PKG", pkg))
print("keep-alive service and Termux bridge written to", main.parent, "package", pkg)
