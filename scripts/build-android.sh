#!/usr/bin/env bash
# 交叉编译罗网 Android 内核（cmd/dragnetvpn：完整 TUN 处理链 + 规则引擎，C ABI + JNI）。
# 用法：bash scripts/build-android.sh [ndk 路径]
#   ndk 路径缺省取 $ANDROID_NDK，再缺省 C:\Data\tools\android-sdk\ndk\30.0.16248370
# 产物：build/android/<abi>/libdragnet.so（Gradle jniLibs 直接引用该目录）
# 注意：用 NDK 的 target-clang.cmd 包装器（自带 --target/sysroot/API 级别）；
#       直接用裸 clang.exe 在 Windows 下 sysroot/三元组处理有坑。Git Bash 下运行。
# 验证导出：llvm-nm -D 产物 | grep -E "Dragnet|Java_"

set -euo pipefail

NDK="${1:-${ANDROID_NDK:-/c/Data/tools/android-sdk/ndk/30.0.16248370}}"
BIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
OUT="build/android"

if [ ! -f "$BIN/aarch64-linux-android21-clang.cmd" ]; then
  echo "错误: 找不到 NDK 包装器: $BIN" >&2
  exit 1
fi

build_one() { # $1=goarch $2=abi $3=triple $4=api
  echo "== $2 (android/$1, API $4) =="
  GOOS=android GOARCH="$1" CGO_ENABLED=1 \
  CC="$(cygpath -w "$BIN/$3-android$4-clang.cmd")" \
    go build -trimpath -tags with_gvisor -buildmode=c-shared -ldflags "-s -w" \
    -o "$OUT/$2/libdragnet.so" ./cmd/dragnetvpn
  # cgo 生成的头文件收进统一目录备查
  mv "$OUT/$2/libdragnet.h" "$OUT/libdragnet-$2.h" 2>/dev/null || true
  ls -la "$OUT/$2/libdragnet.so"
}

mkdir -p "$OUT"
build_one arm64 arm64-v8a aarch64-linux 21
build_one amd64 x86_64 x86_64-linux 21
echo "完成。"
