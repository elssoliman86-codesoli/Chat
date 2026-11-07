package com.codesoli.omni_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

object TermuxRunRegistry {
    private data class Pending(
        val result: MethodChannel.Result,
        val timeout: Runnable
    )

    private val ids = AtomicInteger(10_000)
    private val handler = Handler(Looper.getMainLooper())
    private val pending = ConcurrentHashMap<Int, Pending>()

    fun nextId(): Int = ids.incrementAndGet()

    fun register(id: Int, result: MethodChannel.Result, timeoutMs: Int) {
        val timeout = Runnable {
            completeError(id, "timeout", "Termux command timed out after ${timeoutMs / 1000} seconds.")
        }
        pending[id] = Pending(result, timeout)
        handler.postDelayed(timeout, timeoutMs.toLong())
    }

    fun complete(id: Int, values: Map<String, Any?>) {
        val item = pending.remove(id) ?: return
        handler.removeCallbacks(item.timeout)
        item.result.success(values)
    }

    fun fail(id: Int, code: String, message: String) {
        completeError(id, code, message)
    }

    private fun completeError(id: Int, code: String, message: String) {
        val item = pending.remove(id) ?: return
        handler.removeCallbacks(item.timeout)
        item.result.error(code, message, null)
    }
}

class TermuxResultReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_EXECUTION_ID = "omni.termux.execution_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val executionId = intent.getIntExtra(EXTRA_EXECUTION_ID, -1)
        if (executionId < 0) return
        val bundle: Bundle? = intent.getBundleExtra("result")
        val values = mapOf<String, Any?>(
            "stdout" to (bundle?.getString("stdout") ?: ""),
            "stderr" to (bundle?.getString("stderr") ?: ""),
            "exitCode" to (bundle?.getInt("exitCode") ?: -1),
            "errmsg" to (bundle?.getString("errmsg") ?: ""),
            "err" to (bundle?.getInt("err") ?: 0)
        )
        TermuxRunRegistry.complete(executionId, values)
    }
}
