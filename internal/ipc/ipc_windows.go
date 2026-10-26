//go:build windows

// Package ipc 实现罗网的本机控制通道（M3「服务+GUI 本机 IPC」）：
// 命名管道 \\.\pipe\DragnetCtl 上的版本化 JSON-lines 协议。
//
// 安全边界（威胁模型 TB2）：
//   - DACL：SYSTEM + Administrators + 当前交互用户（构造时取本进程 token 的
//     用户 SID 拼入 SDDL），其余进程打不开管道；
//   - 对端校验：连接后用 GetNamedPipeClientProcessId 反查客户端映像路径，
//     默认要求与服务的 VerifyClient 决策一致（CLI 默认只放行已知罗网组件名）；
//   - 协议：请求 {"v":1,"cmd":...}，应答 {"v":1,"ok":...}；行长上限 4KB，
//     防注入过载（T2.2）。
package ipc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/SYTKILLER/Dragnet/internal/procid"
)

// PipeName 是控制管道的 Win32 路径。
const PipeName = `\\.\pipe\DragnetCtl`

// ProtocolVersion 是当前协议版本。
const ProtocolVersion = 1

const maxLineLen = 4 * 1024

// Request 是控制请求。
type Request struct {
	Version int    `json:"v"`
	Cmd     string `json:"cmd"`
	Domain  string `json:"domain,omitempty"`
	Count   int    `json:"count,omitempty"`
}

// BlockEvent 是一条拦截事件（回溯 UI 数据源）。
type BlockEvent struct {
	Time    time.Time `json:"time"`
	Kind    string    `json:"kind"` // dns|tcp|udp
	Domain  string    `json:"domain,omitempty"`
	Rule    string    `json:"rule,omitempty"`
	List    string    `json:"list,omitempty"`
	Dest    string    `json:"dest,omitempty"`
	Process string    `json:"process,omitempty"`
}

// Status 是服务状态快照。
type Status struct {
	Blocks int    `json:"blocks"`
	Uptime string `json:"uptime,omitempty"`
}

// Response 是控制应答。
type Response struct {
	Version int             `json:"v"`
	OK      bool            `json:"ok"`
	Err     string          `json:"err,omitempty"`
	Data    json.RawMessage `json:"data,omitempty"`
}

// Handler 处理控制命令；返回的数据将被 JSON 编码进应答。
type Handler interface {
	Status() any
	Blocks(count int) []BlockEvent
	Allow(domain string) error // 加入白名单并热切换
	Deny(domain string) error  // 移出白名单并热切换
	Allowlist() []string
}

// Server 命名管道服务端。
type Server struct {
	handler Handler
	// VerifyClient 决定是否接受对端进程；pid 为 0 时（取不到）恒拒绝。
	VerifyClient func(pid uint32) error
	sdMu         sync.Mutex
	closeCh      chan struct{}
}

// NewServer 构建服务端；allowAny 为 true 时跳过对端进程名校验（仅路径校验留日志）。
func NewServer(h Handler, allowAny bool) (*Server, error) {
	s := &Server{handler: h, closeCh: make(chan struct{})}
	self, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("ipc: 取自身路径: %w", err)
	}
	selfDir := filepath.Dir(self)
	s.VerifyClient = func(pid uint32) error {
		if pid == 0 {
			return fmt.Errorf("无法识别客户端进程")
		}
		if allowAny {
			return nil
		}
		// 默认白名单：仅罗网自家组件可控制服务（基线 §6 对端校验）。
		base := strings.ToLower(filepath.Base(procid.ImagePath(pid)))
		switch base {
		case "dragnetctl.exe", "dragnet-gui.exe", "dragnetd.exe":
			return nil
		}
		// 同目录的任意进程也放行（开发期便利；正式版收紧为签名校验）。
		if dir := filepath.Dir(procid.ImagePath(pid)); strings.EqualFold(dir, selfDir) {
			return nil
		}
		return fmt.Errorf("客户端进程 %s 不在允许列表", base)
	}
	return s, nil
}

// Serve 阻塞接受连接（每连接一个 goroutine）。TODO(v1): 优雅停止（当前
// ConnectNamedPipe 阻塞，服务随进程退出）。
func (s *Server) Serve() error {
	sa, err := securityAttributesCurrentUser()
	if err != nil {
		return err
	}
	for {
		select {
		case <-s.closeCh:
			return nil
		default:
		}
		h, err := windows.CreateNamedPipe(windows.StringToUTF16Ptr(PipeName),
			windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_FIRST_PIPE_INSTANCE,
			windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT,
			windows.PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, sa)
		if err != nil {
			// 第二个实例起不能再带 FIRST_PIPE_INSTANCE 标志。
			h, err = windows.CreateNamedPipe(windows.StringToUTF16Ptr(PipeName),
				windows.PIPE_ACCESS_DUPLEX,
				windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT,
				windows.PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, sa)
			if err != nil {
				return fmt.Errorf("ipc: CreateNamedPipe: %w", err)
			}
		}
		if err := windows.ConnectNamedPipe(h, nil); err != nil && err != windows.ERROR_PIPE_CONNECTED {
			windows.CloseHandle(h)
			continue
		}
		go s.handle(h)
	}
}

func (s *Server) handle(h windows.Handle) {
	defer windows.CloseHandle(h)

	// 对端校验：连接一建立即反查 PID（基线 TB2/T2.1）。
	var pid uint32
	_ = windows.GetNamedPipeClientProcessId(h, &pid)
	if s.VerifyClient != nil {
		if err := s.VerifyClient(pid); err != nil {
			return
		}
	}

	f := os.NewFile(uintptr(h), PipeName)
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, maxLineLen), maxLineLen)
	w := bufio.NewWriter(f)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		resp := s.dispatch(line)
		b, _ := json.Marshal(resp)
		w.Write(b)
		w.WriteByte('\n')
		w.Flush()
	}
}

func (s *Server) dispatch(line []byte) Response {
	var req Request
	if err := json.Unmarshal(line, &req); err != nil {
		return Response{Version: ProtocolVersion, Err: "bad request"}
	}
	if req.Version != ProtocolVersion {
		return Response{Version: ProtocolVersion, Err: fmt.Sprintf("version mismatch: want %d", ProtocolVersion)}
	}
	// 命令与域名参数白名单字符校验（防 IPC 注入进规则文件，T2.2）。
	if req.Domain != "" && !validDomain(req.Domain) {
		return Response{Version: ProtocolVersion, Err: "invalid domain"}
	}

	var data any
	var err error
	switch req.Cmd {
	case "status":
		data = s.handler.Status()
	case "blocks":
		n := req.Count
		if n <= 0 || n > 256 {
			n = 50
		}
		data = s.handler.Blocks(n)
	case "allow":
		err = s.handler.Allow(req.Domain)
	case "deny":
		err = s.handler.Deny(req.Domain)
	case "allowlist":
		data = s.handler.Allowlist()
	default:
		return Response{Version: ProtocolVersion, Err: "unknown cmd: " + req.Cmd}
	}
	if err != nil {
		return Response{Version: ProtocolVersion, Err: err.Error()}
	}
	if data == nil {
		data = struct{}{}
	}
	b, merr := json.Marshal(data)
	if merr != nil {
		return Response{Version: ProtocolVersion, Err: merr.Error()}
	}
	return Response{Version: ProtocolVersion, OK: true, Data: b}
}

// validDomain 限制域名字符（字母数字点连字符下划线），拒绝任何控制字符。
func validDomain(s string) bool {
	if len(s) == 0 || len(s) > 253 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		case r >= 'A' && r <= 'Z':
		case r == '.' || r == '-' || r == '_':
		default:
			return false
		}
	}
	return true
}

// Call 是客户端：发送一条命令并返回应答。
func Call(req Request, timeout time.Duration) (*Response, error) {
	req.Version = ProtocolVersion
	line, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)

	var h windows.Handle
	for {
		h, err = windows.CreateFile(windows.StringToUTF16Ptr(PipeName),
			windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil,
			windows.OPEN_EXISTING, 0, 0)
		if err == nil {
			break
		}
		// 管道尚不存在或忙：等一等再试（GUI 启动时服务可能未就绪）。
		if eno, ok := err.(syscall.Errno); ok &&
			(eno == windows.ERROR_FILE_NOT_FOUND || eno == windows.ERROR_PIPE_BUSY) {
			if time.Now().After(deadline) {
				return nil, fmt.Errorf("ipc: 连接管道超时")
			}
			time.Sleep(200 * time.Millisecond)
			continue
		}
		return nil, fmt.Errorf("ipc: 连接管道: %w", err)
	}
	defer windows.CloseHandle(h)

	f := os.NewFile(uintptr(h), PipeName)
	if _, err := f.Write(append(line, '\n')); err != nil {
		return nil, fmt.Errorf("ipc: 发送: %w", err)
	}
	r := bufio.NewReader(f)
	fb, err := r.ReadBytes('\n')
	if err != nil && len(fb) == 0 {
		return nil, fmt.Errorf("ipc: 读取应答: %w", err)
	}
	var resp Response
	if err := json.Unmarshal(fb, &resp); err != nil {
		return nil, fmt.Errorf("ipc: 解析应答: %w", err)
	}
	return &resp, nil
}

// securityAttributesCurrentUser 构造 DACL：SYSTEM + Administrators + 当前用户。
func securityAttributesCurrentUser() (*windows.SecurityAttributes, error) {
	token := windows.GetCurrentProcessToken()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, fmt.Errorf("ipc: 取用户 SID: %w", err)
	}
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;" + user.User.Sid.String() + ")"
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return nil, fmt.Errorf("ipc: SDDL: %w", err)
	}
	return &windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: sd,
	}, nil
}
