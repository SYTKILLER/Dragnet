package com.dragnet.app

/**
 * 罗网 Android 内核入口。符号由 cmd/dragnetvpn（Go, cgo //export）提供，
 * 库名 libdragnet.so；ABI 契约见 cmd/dragnetvpn/main.go 头注释。
 *
 * nativeStartVpn 返回 0 成功，负数为错误码（-10 已运行 -11 参数错 -12 fd 无效
 * -13 规则加载失败 -14~17 内核初始化失败 -99 内部 panic）。
 */
object DragnetNative {
    init {
        System.loadLibrary("dragnet")
    }

    /** 注册 VpnService 实例（出站 protect 防回环依赖），在 startVpn 之前调用。 */
    external fun nativeSetService(service: Any): Int

    /** fd 来自 VpnService.Builder.establish().detachFd()。 */
    external fun nativeStartVpn(fd: Int, dnsUp: String, mtu: Int): Int

    external fun nativeStopVpn(): Int

    /**
     * 从目录加载外部订阅规则（filesDir/rules 目录下的 txt 文件），0 成功；
     * 失败保留原引擎。须在 nativeStartVpn 之前调用；不调用则用内置种子规则。
     */
    external fun nativeLoadRules(dir: String): Int

    /** 运行统计 JSON；未运行返回 null。 */
    external fun nativeStats(): String?
}
