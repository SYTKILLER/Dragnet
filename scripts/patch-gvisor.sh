#!/usr/bin/env bash
# 生成本地补丁版 gvisor 并以 go.work（不入库）挂 replace。
#
# 背景：真机（HarmonyOS app 沙箱）对系统 netmanager 转交的 VPN tun fd 拒绝
# fstat(2)（EPERM，seccomp/SELinux 加固），上游 gvisor fdbased.New →
# IsSocketFD 的 Fstat 失败会中止 stack.Start（startVpn rc=-17，2026-11-01
# 真机实测）。补丁：fstat 被拒按"非 socket"放行（tun fd 本就不是 packet
# socket）。与 ohos-go 工具链同模式：机器本地目录 + go.work，仓库零内嵌。
#
# 用法：bash scripts/patch-gvisor.sh [补丁目录]
#   缺省 D:/research/gvisor-dragnet（多机各跑一次即可）。
set -euo pipefail

VER="v0.0.0-20260727.0-sing-box-mod.1"
MOD="github.com/sagernet/gvisor@${VER}"
DST="${1:-/d/research/gvisor-dragnet}"

if [ -f "$DST/pkg/tcpip/link/fdbased/endpoint.go" ] && grep -q "Dragnet (OHOS) patch" "$DST/pkg/tcpip/link/fdbased/endpoint.go"; then
  echo "补丁版已就位: $DST"
else
  SRC="$(go env GOMODCACHE)/$MOD"
  [ -d "$SRC" ] || { echo "错误: 模块缓存缺 $MOD（先 go mod download）" >&2; exit 1; }
  rm -rf "$DST"
  cp -r "$SRC" "$DST"
  chmod -R u+w "$DST"
  python - "$DST/pkg/tcpip/link/fdbased/endpoint.go" <<'EOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = '''func IsSocketFD(fd int) (bool, error) {
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		return false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)
	}
	return (stat.Mode & unix.S_IFSOCK) == unix.S_IFSOCK, nil
}'''
new = '''func IsSocketFD(fd int) (bool, error) {
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		// Dragnet (OHOS) patch 2026-11-01: HarmonyOS app sandbox (seccomp/
		// SELinux hardening) denies fstat(2) on the VPN tun fd transferred
		// from netmanager -- observed EPERM on a real device (Pura 90),
		// which is never a packet socket in our use. Treat fstat failure
		// as "not a socket" instead of erroring out (upstream behavior
		// would abort New() and break stack.Start with rc=-17).
		return false, nil
	}
	return (stat.Mode & unix.S_IFSOCK) == unix.S_IFSOCK, nil
}'''
assert old in s, 'IsSocketFD 模板不匹配——上游版本变化，需人工核对'
io.open(p, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
print('patched:', p)
EOF
fi

# go.work（不入库）挂 replace；已存在则不覆盖。
if [ ! -f go.work ]; then
  GOVER="$(grep '^go ' go.mod | awk '{print $2}')"
  printf 'go %s\n\nuse .\n\nreplace github.com/sagernet/gvisor => %s\n' "$GOVER" "$DST" > go.work
  echo "已生成 go.work"
fi
go list -m github.com/sagernet/gvisor
echo "完成。go.work 已在 .gitignore，勿提交。"
