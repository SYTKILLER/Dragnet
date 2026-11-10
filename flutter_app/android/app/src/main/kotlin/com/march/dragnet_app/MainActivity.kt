package com.march.dragnet_app

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Flutter 主界面 + 原生桥（dragnet/native）。
 * 内核 JNI 类固定在 com.dragnet.app 包（符号名按 JNI 约定生成）。
 *
 * 自 2026-11-11（M6-A）起 Go 内核运行在独立 :vpn 进程（与 Dart VM 隔离，
 * 对齐鸿蒙壳架构）：本类只做 Messenger IPC 客户端，通道契约（方法名/参数/
 * 返回值）与旧同进程直调 JNI 实现完全一致，Dart 侧零改动。
 */
class MainActivity : FlutterActivity() {

    private var pendingStartResult: MethodChannel.Result? = null

    // ---- :vpn 进程 IPC（Messenger）----
    private var vpnMessenger: Messenger? = null
    private var vpnBound = false

    private class PendingReq(
        val seq: Int,
        val data: Bundle,
        val result: MethodChannel.Result,
        var done: Boolean = false,
    )

    /** 待连接后发送的请求队列。 */
    private val queued = mutableListOf<PendingReq>()
    /** 已发出、等回复的请求（超时/断连时回落 null）。 */
    private val inFlight = mutableListOf<PendingReq>()
    private val seqGen = AtomicInteger(0)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 服务回复统一落在主线程（MethodChannel.Result 非线程安全）。 */
    private val replyMessenger =
        Messenger(object : Handler(Looper.getMainLooper()) {
            override fun handleMessage(msg: Message) {
                val req = inFlight.firstOrNull { it.seq == msg.arg1 } ?: return
                inFlight.remove(req)
                completeReq(req) {
                    val b = msg.data
                    if (b?.containsKey(KEY_ERR) == true) {
                        req.result.error("native", b.getString(KEY_ERR), null)
                    } else if (b?.containsKey(KEY_S) == true) {
                        req.result.success(b.getString(KEY_S))
                    } else if (b?.containsKey(KEY_I) == true) {
                        req.result.success(b.getInt(KEY_I))
                    } else {
                        req.result.success(null)
                    }
                }
            }
        })

    private val vpnConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            vpnMessenger = Messenger(service)
            flushPending()
        }

        override fun onServiceDisconnected(name: ComponentName) {
            vpnMessenger = null
            // :vpn 进程消亡（被杀/崩溃）：挂起请求按"引擎未运行"口径回落 null，
            // 避免 Dart 侧轮询堆积；BIND_AUTO_CREATE 下系统自动重连。
            drainPending()
        }
    }

    private fun completeReq(req: PendingReq, block: () -> Unit) {
        if (req.done) return
        req.done = true
        block()
    }

    private fun flushPending() {
        val m = vpnMessenger ?: return
        val cur = queued.toList()
        queued.clear()
        for (req in cur) {
            val msg = Message.obtain()
            msg.arg1 = req.seq
            msg.data = req.data
            msg.replyTo = replyMessenger
            inFlight.add(req)
            mainHandler.postDelayed({
                // 超时：按"引擎未运行"回落 null（已被回复则 no-op）
                if (inFlight.remove(req)) completeReq(req) { req.result.success(null) }
            }, IPC_TIMEOUT_MS)
            try {
                m.send(msg)
            } catch (e: Exception) {
                if (inFlight.remove(req)) {
                    completeReq(req) { req.result.error("ipc", "send failed: ${e.message}", null) }
                }
            }
        }
    }

    private fun drainPending() {
        val cur = (queued + inFlight).toList()
        queued.clear()
        for (req in cur) completeReq(req) { req.result.success(null) }
        inFlight.clear()
    }

    /** 经 :vpn 进程 IPC 调引擎方法；未连接时入队（连接后 flush，6s 超时回落 null）。 */
    private fun ipcCall(method: String, result: MethodChannel.Result, fill: (Bundle) -> Unit = {}) {
        val data = Bundle().apply {
            putString(KEY_METHOD, method)
            fill(this)
        }
        queued.add(PendingReq(seqGen.incrementAndGet(), data, result))
        bindVpn()
        flushPending()
    }

    private fun bindVpn() {
        if (vpnBound) return
        vpnBound = true
        val intent = Intent(this, com.dragnet.app.DragnetVpnService::class.java)
            .setAction(com.dragnet.app.DragnetVpnService.ACTION_BIND)
        bindService(intent, vpnConnection, Context.BIND_AUTO_CREATE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bindVpn()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startBlock" -> handleStartBlock(result)
                    "stopBlock" -> {
                        startService(
                            Intent(this, com.dragnet.app.DragnetVpnService::class.java)
                                .setAction(com.dragnet.app.DragnetVpnService.ACTION_STOP)
                        )
                        result.success(true)
                    }
                    // 引擎类方法全部走 :vpn IPC（stats/ruleInfo/match/logs/
                    // lastError/reloadRules/lastStartRc）
                    "stats" -> ipcCall("stats", result)
                    "ruleInfo" -> ipcCall("ruleInfo", result)
                    "match" -> ipcCall("match", result) {
                        it.putString(KEY_DOMAIN, call.argument<String>("domain") ?: "")
                    }
                    "logs" -> ipcCall("logs", result) {
                        // Dart int 经标准编解码可能是 Integer 或 Long，统一取 Number。
                        it.putLong(KEY_CURSOR, call.argument<Number>("cursor")?.toLong() ?: 0L)
                    }
                    "lastError" -> ipcCall("lastError", result)
                    "reloadRules" -> ipcCall("reloadRules", result) {
                        it.putString(KEY_DIR, call.argument<String>("dir") ?: "")
                    }
                    "lastStartRc" -> ipcCall("lastStartRc", result)
                    "rulesDir" -> result.success(File(filesDir, "rules").absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleStartBlock(result: MethodChannel.Result) {
        // API 33+ 前台通知需运行时通知权限（M6-A targetSdk 36 合规补充）
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), REQ_NOTIF)
        }
        val intent = VpnService.prepare(this)
        if (intent == null) {
            startVpnService()
            result.success(true)
        } else {
            pendingStartResult = result
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_VPN)
        }
    }

    private fun startVpnService() {
        startService(
            Intent(this, com.dragnet.app.DragnetVpnService::class.java)
                .setAction(com.dragnet.app.DragnetVpnService.ACTION_START)
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            val granted = resultCode == Activity.RESULT_OK
            if (granted) startVpnService()
            pendingStartResult?.success(granted)
            pendingStartResult = null
        }
    }

    private companion object {
        const val CHANNEL = "dragnet/native"
        const val REQ_VPN = 20260
        const val REQ_NOTIF = 20261
        const val KEY_METHOD = com.dragnet.app.DragnetVpnService.KEY_METHOD
        const val KEY_DOMAIN = com.dragnet.app.DragnetVpnService.KEY_DOMAIN
        const val KEY_CURSOR = com.dragnet.app.DragnetVpnService.KEY_CURSOR
        const val KEY_DIR = com.dragnet.app.DragnetVpnService.KEY_DIR
        const val KEY_S = com.dragnet.app.DragnetVpnService.KEY_S
        const val KEY_I = com.dragnet.app.DragnetVpnService.KEY_I
        const val KEY_ERR = com.dragnet.app.DragnetVpnService.KEY_ERR
        const val IPC_TIMEOUT_MS = 6000L
    }
}
