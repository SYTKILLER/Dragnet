package com.march.dragnet_app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Flutter 主界面 + 原生桥（dragnet/native）。
 * 内核 JNI 类固定在 com.dragnet.app 包（符号名按 JNI 约定生成）。
 */
class MainActivity : FlutterActivity() {

    private var pendingStartResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    "stats" -> result.success(com.dragnet.app.DragnetNative.nativeStats())
                    "ruleInfo" -> result.success(com.dragnet.app.DragnetNative.nativeRuleInfo())
                    "match" -> result.success(
                        com.dragnet.app.DragnetNative.nativeMatch(
                            call.argument<String>("domain") ?: ""
                        )
                    )
                    "rulesDir" -> result.success(File(filesDir, "rules").absolutePath)
                    "lastStartRc" -> result.success(com.dragnet.app.DragnetVpnService.lastStartRc)
                    // 以下三个 JNI 调用包 try/catch UnsatisfiedLinkError：
                    // 旧 libdragnet.so 可能未含新符号，缺失时降级返回 null/-99，
                    // 防止壳进程崩溃。
                    "logs" -> result.success(
                        try {
                            // Dart int 经标准编解码可能是 Integer 或 Long，统一取 Number。
                            com.dragnet.app.DragnetNative.nativeLogs(
                                call.argument<Number>("cursor")?.toLong() ?: 0L
                            )
                        } catch (e: UnsatisfiedLinkError) {
                            null
                        }
                    )
                    "lastError" -> result.success(
                        try {
                            com.dragnet.app.DragnetNative.nativeLastError()
                        } catch (e: UnsatisfiedLinkError) {
                            null
                        }
                    )
                    "reloadRules" -> result.success(
                        try {
                            // 复用既有 nativeLoadRules 导出（无新符号）。
                            com.dragnet.app.DragnetNative.nativeLoadRules(
                                call.argument<String>("dir") ?: ""
                            )
                        } catch (e: UnsatisfiedLinkError) {
                            -99
                        }
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleStartBlock(result: MethodChannel.Result) {
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
    }
}
