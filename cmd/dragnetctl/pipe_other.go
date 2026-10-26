//go:build !windows

package main

import (
	"fmt"
	"os"
)

// pipeMain 在非 Windows 平台不可用（控制管道是 Windows 服务化阶段的平台细节）。
func pipeMain([]string) int {
	fmt.Fprintln(os.Stderr, "dragnetctl: -pipe 仅支持 Windows")
	return 2
}
