package com.codesoli.omni_chat

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "omni/termux"
        private const val TERMUX_PACKAGE = "com.termux"
        private const val RUN_PERMISSION = "com.termux.permission.RUN_COMMAND"
        private const val REQUEST_RUN_PERMISSION = 7314
        private const val MAX_COMMAND_BYTES = 128 * 1024
        private const val DEFAULT_WORKDIR = "/data/data/com.termux/files/home"
        private const val TERMUX_BASH = "/data/data/com.termux/files/usr/bin/bash"
    }

    private var permissionResult: MethodChannel.Result? = null

    override fun onConfigureFlutterEngine(flutterEngine: FlutterEngine) {
        super.onConfigureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isInstalled" -> result.success(isTermuxInstalled())
                "hasPermission" -> result.success(hasRunPermission())
                "requestPermission" -> requestRunPermission(result)
                "run" -> {
                    val command = call.argument<String>("command").orEmpty()
                    val workdir = call.argument<String>("workdir").orEmpty().ifBlank { DEFAULT_WORKDIR }
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 60_000
                    runInTermux(command, workdir, timeoutMs, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isTermuxInstalled(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                packageManager.getPackageInfo(TERMUX_PACKAGE, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(TERMUX_PACKAGE, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun hasRunPermission(): Boolean {
        return Build.VERSION.SDK_INT < 23 || checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestRunPermission(result: MethodChannel.Result) {
        if (!isTermuxInstalled()) {
            result.success(false)
            return
        }
        if (hasRunPermission()) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("permission_in_progress", "A Termux permission request is already pending.", null)
            return
        }
        permissionResult = result
        requestPermissions(arrayOf(RUN_PERMISSION), REQUEST_RUN_PERMISSION)
    }

    @Deprecated("Deprecated by Android, retained for FlutterActivity permission callback compatibility.")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_RUN_PERMISSION) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    private fun runInTermux(
        command: String,
        workdir: String,
        timeoutMs: Int,
        result: MethodChannel.Result
    ) {
        if (command.isBlank()) {
            result.error("invalid_command", "Command cannot be empty.", null)
            return
        }
        if (command.toByteArray(Charsets.UTF_8).size > MAX_COMMAND_BYTES) {
            result.error("command_too_large", "Termux RUN_COMMAND supports commands up to approximately 128 KB.", null)
            return
        }
        if (!isTermuxInstalled()) {
            result.error("termux_missing", "Termux is not installed.", null)
            return
        }
        if (!hasRunPermission()) {
            result.error("permission_denied", "Grant the Run commands in Termux environment permission in Android app settings.", null)
            return
        }

        val executionId = TermuxRunRegistry.nextId()
        val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pendingIntentFlags = PendingIntent.FLAG_ONE_SHOT or mutableFlag
        val callbackIntent = Intent(this, TermuxResultReceiver::class.java).apply {
            putExtra(TermuxResultReceiver.EXTRA_EXECUTION_ID, executionId)
        }
        val callback = PendingIntent.getBroadcast(this, executionId, callbackIntent, pendingIntentFlags)
        val runIntent = Intent("com.termux.RUN_COMMAND").apply {
            setClassName(TERMUX_PACKAGE, "com.termux.app.RunCommandService")
            putExtra("com.termux.RUN_COMMAND_PATH", TERMUX_BASH)
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-lc", command))
            putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", false)
            // Keep the Termux session in the background instead of stealing focus from Omni Chat.
            putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", 3)
            putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", callback)
        }

        TermuxRunRegistry.register(executionId, result, timeoutMs.coerceIn(1_000, 300_000))
        try {
            startService(runIntent)
        } catch (error: Exception) {
            TermuxRunRegistry.fail(executionId, "termux_start_failed", error.message ?: error.toString())
        }
    }
}
