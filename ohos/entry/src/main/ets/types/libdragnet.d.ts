// libdragnet.so（cmd/dragnetohos，Go NAPI 模块）的 ArkTS 类型声明。
// 实现见 cmd/dragnetohos/main.go；ABI 契约注释同处。

declare module 'libdragnet.so' {
  /**
   * 启动内核。tunFd 来自 VpnConnection.create()；protectCb(id, fd) 由内核在
   * 出站 socket connect 前回调：JS 侧调 VpnConnection.protect(fd) 后必须
   * 调 setProtected(id) 回握（内核等 5s，超时放弃拨号防回环）。
   * resolve 0 成功 / 负数错误码。
   */
  export const startVpn: (
    tunFd: number, dnsUp: string, mtu: number,
    protectCb: (id: number, fd: number) => void
  ) => Promise<number>;

  /** 停止内核并释放 TUN。0 成功；1 未运行；负数错误。 */
  export const stopVpn: () => number;

  /** protect 完成回握：唤醒等待 connect 的内核。 */
  export const setProtected: (id: number) => void;

  /**
   * 从目录加载全部 .txt 规则并原子切换引擎（须在 startVpn 之前）。
   * 0 成功；-1 参数空；-2 目录不可读；-3 加载失败。
   */
  export const loadRules: (dir: string) => number;

  /** 运行统计 JSON；未运行返回 ""。 */
  export const stats: () => string;

  /** 域名匹配自检（无网络副作用）；引擎空载返回 ""，否则 JSON {action,rule,list}。 */
  export const match: (domain: string) => string;
}
