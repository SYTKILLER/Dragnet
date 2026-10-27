#!/usr/bin/env bash
# 交叉编译罗网 HarmonyOS 内核（cmd/dragnetohos：完整 TUN 处理链 + 规则引擎，
# NAPI 模块本体）。
# 工具链：sysit/ohos-go（golang/go fork，GOOS=openharmony，含 x86_64 TLS
# descriptor/global-dynamic 支持——上游 Go 的 initial-exec TLS 重定位会被
# OHOS musl 加载器在 dlopen 时拒绝）。工具链源码获取与构建见 ohos/README.md。
# GOOS=openharmony 同时满足 "linux" 构建标签（sing-tun/gvisor 直接编译），
# 并在 c-shared 下自动启用 TLS GD（obj/x86/asm6.go isOpenharmony 分支）。
# NAPI 桥：github.com/likuai2010/ohos-napi（MIT，ClashBox 同源）。
# 配方参考 ClashBox（xiaobaigroup/ClashBox，GPL-3.0）。
# 用法：bash scripts/build-ohos.sh [OHOS_NATIVE_HOME] [GOOHOS_ROOT]
#   OHOS_NATIVE_HOME 缺省 DevEco 自带 SDK：
#   C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native
#   GOOHOS_ROOT 缺省 D:\research\ohos-go（首次需 make.bat 构建，见 ohos/README.md）
# 产物：build/ohos/<abi>/libdragnet.so（NAPI 模块，壳工程直接 import）
# 注意：模拟器镜像为 x86_64（默认编译 amd64）；真机 arm64 待签名后加。
# 验证导出：llvm-nm -D 产物 | grep -iE "napi|Dragnet"
# Git Bash 下运行。

set -euo pipefail

NATIVE="${1:-"/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"}"
NATIVE="$(cygpath -u "$NATIVE" 2>/dev/null || echo "$NATIVE")"
GOOHOS_ROOT="${2:-/d/research/ohos-go}"
GOOHOS="$GOOHOS_ROOT/bin/go.exe"
BIN="$NATIVE/llvm/bin"
OUT="build/ohos"

if [ ! -f "$GOOHOS" ]; then
  echo "错误: 找不到 ohos-go 工具链: $GOOHOS（构建方法见 ohos/README.md）" >&2
  exit 1
fi
if [ ! -f "$BIN/clang.exe" ] && [ ! -f "$BIN/clang" ]; then
  echo "错误: 找不到 OHOS LLVM 工具链: $BIN" >&2
  exit 1
fi
CLANG="$BIN/clang.exe"; [ -f "$CLANG" ] || CLANG="$BIN/clang"

# cgo 的 CC 不吃带空格路径，且 CGO_CFLAGS/LDFLAGS 白名单拒绝 --target——
# 生成 .cmd 包装器把 target/sysroot 藏进编译器调用（Android NDK 同思路）。
build_one() { # $1=goarch $2=abi目录 $3=target三元组
  echo "== $2 (openharmony/$1, target $3-linux-ohos) =="
  mkdir -p "$OUT/$2"
  local short wrapper
  short="$(cygpath -d "$NATIVE")"
  wrapper="$(cygpath -w "$PWD")\\$OUT\\$3-ohos-clang.cmd"
  {
    echo "@echo off"
    echo "\"$short\\llvm\\bin\\clang.exe\" --target=$3-linux-ohos --sysroot=\"$short\\sysroot\" --sysroot=\"$short\\sysroot\" %*"
  } > "$OUT/$3-ohos-clang.cmd"
  GOOS=openharmony GOARCH="$1" CGO_ENABLED=1 \
  CC="$wrapper" \
  CGO_AR="$short\\llvm\\bin\\llvm-ar.exe" \
  CGO_CFLAGS="-Wno-error -D__MUSL__" \
    "$GOOHOS" build -trimpath -tags "ohos with_gvisor osusergo" \
    -buildmode=c-shared -o "$OUT/$2/libdragnet.so" ./cmd/dragnetohos
  # 合格的 GD 产物：无 initial-exec TLS 重定位（TPOFF），有 TLS descriptor
  "$BIN/llvm-readelf.exe" -r "$OUT/$2/libdragnet.so" 2>/dev/null | grep -i "TPOFF" && \
    { echo "错误: 仍存在 initial-exec TLS 重定位" >&2; exit 1; } || echo "TLS 检查: 无 TPOFF (GD 模式生效)"
  "$BIN/llvm-nm.exe" -D "$OUT/$2/libdragnet.so" 2>/dev/null | grep -iE "_register_napiGoOH|InitializeModule" || true
  ls -la "$OUT/$2/libdragnet.so"
}

# 模拟器（Pura 90 等）为 x86_64 镜像；真机为 arm64（v8a，内核侧无需签名即可产出）。
build_one amd64 x86_64 x86_64
build_one arm64 arm64-v8a aarch64
echo "完成。"
