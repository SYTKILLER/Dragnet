//go:build !windows

// Package ipc 的非 Windows 空实现：GUI 控制通道是 Windows 服务化阶段的
// 平台细节；其他平台另行适配（Android 壳直接进程内调用，无需 IPC）。
package ipc

import (
	"errors"
	"time"
)

var errWindowsOnly = errors.New("ipc: 仅 Windows 实现")

// Server 在非 Windows 平台不可用。
type Server struct{}

// NewServer 恒返回错误。
func NewServer(h Handler, allowAny bool) (*Server, error) { return nil, errWindowsOnly }

// Serve 恒返回错误。
func (*Server) Serve() error { return errWindowsOnly }

// BlockEvent 恒为零值。
type BlockEvent struct{}

// Call 恒返回错误。
func Call(req Request, timeout time.Duration) (*Response, error) { return nil, errWindowsOnly }
