package com.dragnet.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File

/**
 * M2 核心薄切片薄壳：establish 拿 fd → 外部规则（filesDir/rules）→ 注册
 * protect → 前台通知保活 → 起停 Go 内核。
 * 地址/DNS 与 cmd/dragnetvpn/main.go 的 tunAddr/tunDNSAddr 常量保持一致：
 * DNS 指向 10.111.222.3，包进入 TUN 后被内核劫持判定。
 */
class DragnetVpnService : VpnService() {

    override fun onBind(intent: Intent?): IBinder = super.onBind(intent)!!

    override fun onCreate() {
        super.onCreate()
        createChannel()
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
            stopSelf()
            return
        }
        // fd 所有权移交 Go 内核（nativeStopVpn 关闭）
        val fd = pfd.detachFd()
        DragnetNative.nativeSetService(this)
        // 外部订阅（adb push *.txt → /data/data/com.dragnet.app/files/rules/）；
        // 失败或无目录则继续用内置种子
        val rulesDir = File(filesDir, "rules")
        if (rulesDir.isDirectory) {
            val rc = DragnetNative.nativeLoadRules(rulesDir.absolutePath)
            Log.i(TAG, "nativeLoadRules(${rulesDir.absolutePath}) = $rc")
        } else {
            Log.i(TAG, "无外部规则目录，使用内置种子规则")
        }
        val rc = DragnetNative.nativeStartVpn(fd, DNS_UP, MTU)
        Log.i(TAG, "nativeStartVpn(fd=$fd, dns=$DNS_UP, mtu=$MTU) = $rc")
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
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
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
        const val MTU = 1500
        const val DNS_UP = "223.5.5.5:53"
        const val CHANNEL_ID = "dragnet"
        const val NOTIFY_ID = 1
    }
}
