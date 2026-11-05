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

main.write_text(MAIN.replace("PKG", pkg))
(main.parent / "KeepAliveService.kt").write_text(SERVICE.replace("PKG", pkg))
print("keep-alive service written to", main.parent, "package", pkg)
