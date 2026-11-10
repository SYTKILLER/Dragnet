package com.dragnet.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.util.Log
import java.io.File

/**
 * 罗网 Android 内核宿主——运行在独立 :vpn 进程（2026-11-11 M6-A，对齐鸿蒙壳
 * UI 进程/VPN 扩展进程分离架构）。本进程不含 Dart VM；Go runtime 仅在此加载。
 * UI 进程经 Messenger IPC 访问引擎：stats / ruleInfo / match / logs /
 * reloadRules / lastStartRc / lastError（返回值与旧同进程 MainActivity 直调
 * JNI 的通道契约逐方法一致，Dart 侧零改动）。
 *
 * VPN 链路（与 PoC 壳逻辑一致）：establish 拿 fd → 外部规则（filesDir/rules）→
 * 注册 protect → 前台通知保活 → 起停 Go 内核。
 * 地址/DNS 与 cmd/dragnetvpn/main.go 的 tunAddr/tunDNSAddr 常量保持一致：
 * DNS 指向 10.111.222.3，包进入 TUN 后被内核劫持判定。
 */
class DragnetVpnService : VpnService() {

    private var ipcThread: HandlerThread? = null
    private lateinit var ipcMessenger: Messenger

    /** IPC 请求在专用线程处理（JNI 调用不阻塞 :vpn 主线程）。 */
    private inner class IpcHandler(looper: Looper) : Handler(looper) {
        override fun handleMessage(msg: Message) {
            val data = msg.data ?: Bundle.EMPTY
            val method = data.getString(KEY_METHOD) ?: return
            val b = Bundle()
            try {
                when (method) {
                    "stats" -> b.putString(KEY_S, DragnetNative.nativeStats())
                    "ruleInfo" -> b.putString(KEY_S, DragnetNative.nativeRuleInfo())
                    "match" -> b.putString(
                        KEY_S, DragnetNative.nativeMatch(data.getString(KEY_DOMAIN) ?: "")
                    )
                    // 以下三项 try/catch UnsatisfiedLinkError：旧 libdragnet.so 可能
                    // 未含新符号，缺失时降级（对齐旧 MainActivity 通道行为）。
                    "logs" -> b.putString(
                        KEY_S,
                        try {
                            DragnetNative.nativeLogs(
                                if (data.containsKey(KEY_CURSOR)) data.getLong(KEY_CURSOR) else 0L
                            )
                        } catch (e: UnsatisfiedLinkError) {
                            null
                        }
                    )
                    "lastError" -> b.putString(
                        KEY_S,
                        try {
                            DragnetNative.nativeLastError()
                        } catch (e: UnsatisfiedLinkError) {
                            null
                        }
                    )
                    "reloadRules" -> b.putInt(
                        KEY_I,
                        try {
                            DragnetNative.nativeLoadRules(data.getString(KEY_DIR) ?: "")
                        } catch (e: UnsatisfiedLinkError) {
                            -99
                        }
                    )
                    "lastStartRc" -> b.putInt(KEY_I, lastStartRc)
                    else -> b.putString(KEY_ERR, "unknown method $method")
                }
            } catch (e: UnsatisfiedLinkError) {
                // stats/ruleInfo/match 未守护：转通道错误（旧实现同样抛出）
                b.putString(KEY_ERR, "native link error: ${e.message}")
            } catch (e: Throwable) {
                b.putString(KEY_ERR, "${e.javaClass.simpleName}: ${e.message}")
            }
            val reply = Message.obtain()
            reply.arg1 = msg.arg1 // 请求序号回传，供客户端配对
            reply.data = b
            val back = msg.replyTo
            if (back != null) {
                try {
                    back.send(reply)
                } catch (e: Exception) {
                    Log.w(TAG, "IPC reply failed: ${e.message}")
                    reply.recycle()
                }
            } else {
                reply.recycle()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val t = HandlerThread("dragnet-ipc")
        t.start()
        ipcThread = t
        ipcMessenger = Messenger(IpcHandler(t.looper))
    }

    override fun onDestroy() {
        ipcThread?.quitSafely()
        ipcThread = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder {
        // 系统（establish 之后）以 SERVICE_INTERFACE 绑定 = VPN 控制面 binder；
        // 本应用 UI 进程绑定（ACTION_BIND）= Messenger IPC。
        return if (intent?.action == SERVICE_INTERFACE) {
            super.onBind(intent)!!
        } else {
            ipcMessenger.binder
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopVpn()
                return START_NOT_STICKY
            }
            else -> startVpn()
        }
        return START_STICKY
    }

    private fun startVpn() {
        val pfd = Builder()
            .setSession("Dragnet")
            .setMtu(MTU)
            .addAddress("10.111.222.1", 32)
            .addDnsServer("10.111.222.3")
            .addRoute("0.0.0.0", 0)
            .establish()
        if (pfd == null) {
            Log.e(TAG, "establish 失败（用户未授权或参数被拒）")
            lastStartRc = -98
            stopSelf()
            return
        }
        // fd 所有权移交 Go 内核（nativeStopVpn 关闭）
        val fd = pfd.detachFd()
        DragnetNative.nativeSetService(this)
        // 外部订阅（filesDir/rules/*.txt）；失败或无目录则空载 fail-open
        val rulesDir = File(filesDir, "rules")
        if (rulesDir.isDirectory) {
            val rc = DragnetNative.nativeLoadRules(rulesDir.absolutePath)
            Log.i(TAG, "nativeLoadRules(${rulesDir.absolutePath}) = $rc")
        } else {
            Log.i(TAG, "无外部规则目录，空载运行（fail-open）")
        }
        val rc = DragnetNative.nativeStartVpn(fd, DNS_UP, MTU)
        Log.i(TAG, "nativeStartVpn(fd=$fd, dns=$DNS_UP, mtu=$MTU) = $rc")
        lastStartRc = rc
        if (rc != 0) {
            Log.e(TAG, "内核启动失败 rc=$rc")
            stopSelf()
            return
        }
        startForeground(NOTIFY_ID, buildNotification())
    }

    private fun stopVpn() {
        val rc = DragnetNative.nativeStopVpn()
        Log.i(TAG, "nativeStopVpn = $rc")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    private fun createChannel() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "罗网拦截", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun buildNotification(): Notification {
        // 点通知回到 Flutter 主界面
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, com.march.dragnet_app.MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("罗网 · 拦截运行中")
            .setContentText("域名级广告/跟踪拦截（logcat 过滤 Dragnet 查看明细）")
            .setSmallIcon(android.R.drawable.ic_secure)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val TAG = "Dragnet"
        const val ACTION_START = "com.dragnet.app.START"
        const val ACTION_STOP = "com.dragnet.app.STOP"
        const val ACTION_BIND = "com.dragnet.app.BIND"
        const val KEY_METHOD = "method"
        const val KEY_DOMAIN = "domain"
        const val KEY_CURSOR = "cursor"
        const val KEY_DIR = "dir"
        const val KEY_S = "result_s"
        const val KEY_I = "result_i"
        const val KEY_ERR = "result_err"
        const val MTU = 1500
        const val DNS_UP = "223.5.5.5:53"
        const val CHANNEL_ID = "dragnet"
        const val NOTIFY_ID = 1

        /** 最近一次内核启动错误码（0=成功/未失败），IPC lastStartRc 透出。 */
        @Volatile
        var lastStartRc: Int = 0
    }
}
