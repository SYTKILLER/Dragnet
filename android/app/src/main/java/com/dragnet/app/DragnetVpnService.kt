package com.dragnet.app

import android.content.Intent
import android.net.VpnService
import android.os.IBinder
import android.util.Log

/**
 * P0-A 最小链路薄壳：establish 拿 fd → 注册 protect → 起停 Go 内核。
 * 地址/DNS 与 cmd/dragnetvpn/main.go 的 tunAddr/tunDNSAddr 常量保持一致：
 * DNS 指向 10.111.222.3，包进入 TUN 后被内核劫持判定。
 */
class DragnetVpnService : VpnService() {

    override fun onBind(intent: Intent?): IBinder = super.onBind(intent)!!

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
        val rc = DragnetNative.nativeStartVpn(fd, DNS_UP, MTU)
        Log.i(TAG, "nativeStartVpn(fd=$fd, dns=$DNS_UP, mtu=$MTU) = $rc")
        if (rc != 0) {
            Log.e(TAG, "内核启动失败 rc=$rc")
            stopSelf()
        }
    }

    private fun stopVpn() {
        val rc = DragnetNative.nativeStopVpn()
        Log.i(TAG, "nativeStopVpn = $rc")
        stopSelf()
    }

    companion object {
        const val TAG = "Dragnet"
        const val ACTION_START = "com.dragnet.app.START"
        const val ACTION_STOP = "com.dragnet.app.STOP"
        const val MTU = 1500
        const val DNS_UP = "223.5.5.5:53"
    }
}
