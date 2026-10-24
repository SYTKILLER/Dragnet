package com.dragnet.app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 程序化 UI（无 res 依赖）：授权 → 启动/停止 VpnService。
 */
class MainActivity : Activity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(pad, pad, pad, pad)
        }

        status = TextView(this).apply {
            text = "罗网 · Android 最小链路 PoC\n未运行"
            gravity = Gravity.CENTER
        }

        val startBtn = Button(this).apply {
            text = "启动拦截"
            setOnClickListener { requestVpnPermission() }
        }
        val stopBtn = Button(this).apply {
            text = "停止拦截"
            setOnClickListener {
                startService(vpnIntent(DragnetVpnService.ACTION_STOP))
            }
        }

        root.addView(status)
        root.addView(startBtn)
        root.addView(stopBtn)
        setContentView(root)
    }

    private fun vpnIntent(action: String) =
        Intent(this, DragnetVpnService::class.java).setAction(action)

    private fun requestVpnPermission() {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            startActivityForResult(intent, REQ_VPN)
        } else {
            onVpnGranted()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) {
                onVpnGranted()
            } else {
                status.text = "VPN 授权被拒绝"
            }
        }
    }

    private fun onVpnGranted() {
        status.text = "内核启动中…（拦截日志见 logcat: Dragnet）"
        startService(vpnIntent(DragnetVpnService.ACTION_START))
    }

    private companion object {
        const val REQ_VPN = 1
    }
}
