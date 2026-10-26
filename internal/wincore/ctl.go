//go:build windows

// Package wincore 是罗网内核的 Windows 共享装配层：控制台 CLI（cmd/dragnet-tun）
// 与 Windows 服务（cmd/dragnetd）共用的 runCore、控制面（IPC Handler、阻断
// 事件环形缓冲、白名单热切换）与系统 DNS 接管。
//
// 白名单文件位于规则目录（zzz-user-allow.txt，@@||domain^$important 形态），
// 由规则加载器随目录一起加载，$important 保证压过订阅中的普通阻断。
package wincore

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/SYTKILLER/Dragnet/internal/ipc"
)

const userAllowFile = "zzz-user-allow.txt"

// blockRing 是固定容量的最近阻断环形缓冲。
type blockRing struct {
	mu  sync.Mutex
	buf []ipc.BlockEvent
	hi  int // 下一个写入位
	n   int
}

func newBlockRing(cap int) *blockRing {
	return &blockRing{buf: make([]ipc.BlockEvent, cap)}
}

func (r *blockRing) add(ev ipc.BlockEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf[r.hi] = ev
	r.hi = (r.hi + 1) % len(r.buf)
	if r.n < len(r.buf) {
		r.n++
	}
}

// latest 返回最近 n 条（新→旧）。
func (r *blockRing) latest(n int) []ipc.BlockEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n > r.n {
		n = r.n
	}
	out := make([]ipc.BlockEvent, 0, n)
	for i := 0; i < n; i++ {
		idx := (r.hi - 1 - i + len(r.buf)) % len(r.buf)
		out = append(out, r.buf[idx])
	}
	return out
}

// ctlHandler 实现 ipc.Handler。
type ctlHandler struct {
	start    time.Time
	ring     *blockRing
	listsDir string
	reload   func() error // 白名单变更后的引擎热切换（main 提供）
	log      loggerWarnInfo
}

func (c *ctlHandler) Status() any {
	return ipc.Status{Uptime: time.Since(c.start).Round(time.Second).String()}
}

func (c *ctlHandler) Blocks(n int) []ipc.BlockEvent { return c.ring.latest(n) }

func (c *ctlHandler) Allow(domain string) error {
	return c.toggle(domain, true)
}

func (c *ctlHandler) Deny(domain string) error {
	return c.toggle(domain, false)
}

func (c *ctlHandler) Allowlist() []string {
	lines := readUserAllow(c.listsDir)
	sort.Strings(lines)
	return lines
}

// toggle 追加/移除白名单行并热切换引擎。
func (c *ctlHandler) toggle(domain string, add bool) error {
	d := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(domain), "."))
	if d == "" {
		return fmt.Errorf("域名为空")
	}
	path := filepath.Join(c.listsDir, userAllowFile)
	lines := readUserAllow(c.listsDir)
	var out []string
	found := false
	for _, ln := range lines {
		if ln == d {
			found = true
			continue // add 时去重；deny 时移除
		}
		out = append(out, ln)
	}
	if add {
		if !found {
			out = append(out, d)
		}
	}
	var b strings.Builder
	for _, ln := range out {
		fmt.Fprintf(&b, "@@||%s^$important\n", ln)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return fmt.Errorf("写白名单: %w", err)
	}
	if err := c.reload(); err != nil {
		return fmt.Errorf("热切换: %w", err)
	}
	c.log("白名单已更新: ", d, " -> ", map[bool]string{true: "允许", false: "移除"}[add])
	return nil
}

func readUserAllow(dir string) []string {
	f, err := os.Open(filepath.Join(dir, userAllowFile))
	if err != nil {
		return nil
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		ln := strings.TrimSpace(sc.Text())
		// 文件存储 @@||domain^$important 形态，回读纯域名。
		ln = strings.TrimPrefix(ln, "@@||")
		ln = strings.TrimSuffix(ln, "^$important")
		ln = strings.TrimSuffix(ln, "^")
		if ln != "" && !strings.HasPrefix(ln, "!") {
			lines = append(lines, ln)
		}
	}
	return lines
}

// 供 ctlHandler 用的最小日志接口（复用 logAdapter 的方法值）。
type loggerWarnInfo func(args ...any)
