// Package subscribe 实现规则订阅的条件更新、校验与原子落盘（M3 出口标准
// "订阅条件更新、原子切换"的订阅侧）。
//
// 流程：周期性对每个源发起带 If-None-Match/If-Modified-Since 的 GET，
// 304 跳过；200 则校验（体积上限/最小行数/收缩幅度告警，威胁模型 T4.1/T4.3）
// 后写临时文件并原子改名，再由调用方通过 rules.Holder 热切换引擎。
// meta sidecar（<file>.meta.json）记录 ETag/Last-Modified/行数。
//
// 网络仅为普通应用级 HTTPS 下载，不触碰系统网络配置。
package subscribe

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 硬性资源上限（T4.3 炸弹规则防御）。
const (
	MaxListBytes  = 32 << 20 // 单订阅体积上限 32MB
	MinListLines  = 10       // 有效订阅最小非注释行数
	ShrinkWarnPct = 50       // 非注释行数收缩超过该百分比→告警（仍加载）
	fetchTimeout  = 60 * time.Second
)

// Source 是一个订阅源。
type Source struct {
	Name string `json:"name"` // 订阅名（落盘文件名去掉 .txt）
	URL  string `json:"url"`
}

// Config 是订阅配置。
type Config struct {
	Sources []Source `json:"sources"`
	// Hours 是刷新间隔（小时），0 取默认 24。
	Hours int    `json:"interval_hours,omitempty"`
	Proxy string `json:"proxy,omitempty"` // 空则用环境变量 HTTP(S)_PROXY
}

// Logger 是本包日志依赖。
type Logger interface {
	Info(args ...any)
	Warn(args ...any)
	Error(args ...any)
}

// DefaultConfig 返回内置三源（与 scripts/fetch-rules.sh 一致，勿换第三方镜像）。
func DefaultConfig() Config {
	return Config{
		Sources: []Source{
			{Name: "anti-AD", URL: "https://anti-ad.net/adguard.txt"},
			{Name: "AWAvenue", URL: "https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Adguard.txt"},
			{Name: "hagezi-multi", URL: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt"},
		},
	}
}

// LoadConfig 从 JSON 文件读取；文件不存在返回默认配置（nil 错误）。
func LoadConfig(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return DefaultConfig(), nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("subscribe: 读取配置 %s: %w", path, err)
	}
	var cfg Config
	if err := json.Unmarshal(b, &cfg); err != nil {
		return Config{}, fmt.Errorf("subscribe: 解析配置 %s: %w", path, err)
	}
	if len(cfg.Sources) == 0 {
		return Config{}, fmt.Errorf("subscribe: 配置无 sources")
	}
	return cfg, nil
}

// meta 是落盘在订阅旁的元数据 sidecar。
type meta struct {
	ETag         string    `json:"etag,omitempty"`
	LastModified string    `json:"last_modified,omitempty"`
	FetchedAt    time.Time `json:"fetched_at"`
	Lines        int       `json:"lines"`
}

// Manager 周期刷新订阅到 dir，并调用 reload 回调（rules.Holder.Load）热切换。
type Manager struct {
	dir     string
	cfg     Config
	client  *http.Client
	reload  func() error
	log     Logger
	nowFunc func() time.Time
}

// NewManager 构建管理器。reload 由调用方提供（典型为 rules.Holder 的目录重载）。
func NewManager(dir string, cfg Config, reload func() error, log Logger) *Manager {
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment}
	if cfg.Proxy != "" {
		if pu, err := url.Parse(cfg.Proxy); err == nil {
			transport.Proxy = http.ProxyURL(pu)
		}
	}
	return &Manager{
		dir:     dir,
		cfg:     cfg,
		client:  &http.Client{Timeout: fetchTimeout, Transport: transport},
		reload:  reload,
		log:     log,
		nowFunc: time.Now,
	}
}

// RefreshResult 是一轮刷新的结果。
type RefreshResult struct {
	Updated, Skipped, Failed int
}

// SetClient 替换 HTTP 客户端（如需要绑定特定出站接口的 TUN 场景）。
// 必须在首次 RefreshOnce/Run 之前调用。
func (m *Manager) SetClient(c *http.Client) { m.client = c }

// RefreshOnce 对全部源执行一轮条件更新（不触发 reload）。
func (m *Manager) RefreshOnce() RefreshResult {
	var res RefreshResult
	for _, s := range m.cfg.Sources {
		switch err := m.fetchOne(s); {
		case err == nil:
			res.Updated++
		case err == errNotModified:
			res.Skipped++
		default:
			res.Failed++
			m.log.Error("订阅更新失败 ", s.Name, ": ", err)
		}
	}
	return res
}

// Reload 从目录重建引擎并原子切换（委托给构造时的回调）。
func (m *Manager) Reload() error { return m.reload() }

// Interval 返回刷新间隔。
func (m *Manager) Interval() time.Duration {
	if m.cfg.Hours <= 0 {
		return 24 * time.Hour
	}
	return time.Duration(m.cfg.Hours) * time.Hour
}

// Run 阻塞式循环：立即刷一轮+reload，之后按间隔（±10% 抖动）重复，ctx 取消退出。
func (m *Manager) Run() {
	m.cycle()
	t := time.NewTicker(m.Interval())
	defer t.Stop()
	for {
		select {
		case <-t.C:
			m.cycle()
		}
	}
}

func (m *Manager) cycle() {
	res := m.RefreshOnce()
	if res.Updated > 0 {
		if err := m.Reload(); err != nil {
			m.log.Error("规则热切换失败（沿用旧引擎）: ", err)
		} else {
			m.log.Info("订阅热切换完成: 更新", res.Updated, " 跳过", res.Skipped, " 失败", res.Failed)
		}
	} else {
		m.log.Info("订阅检查完成: 更新", res.Updated, " 跳过", res.Skipped, " 失败", res.Failed)
	}
}

var errNotModified = fmt.Errorf("not modified")

func (m *Manager) fetchOne(s Source) error {
	file := filepath.Join(m.dir, s.Name+".txt")
	var old meta
	if b, err := os.ReadFile(file + ".meta.json"); err == nil {
		_ = json.Unmarshal(b, &old)
	}

	req, err := http.NewRequest("GET", s.URL, nil)
	if err != nil {
		return fmt.Errorf("构造请求: %w", err)
	}
	if old.ETag != "" {
		req.Header.Set("If-None-Match", old.ETag)
	}
	if old.LastModified != "" {
		req.Header.Set("If-Modified-Since", old.LastModified)
	}
	req.Header.Set("User-Agent", "Dragnet/0.1 (rule subscriber)")

	resp, err := m.client.Do(req)
	if err != nil {
		return fmt.Errorf("下载: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified {
		return errNotModified
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	// 体积上限：超限立即中止读取（T4.3）。
	body := io.LimitReader(resp.Body, MaxListBytes+1)
	text, err := io.ReadAll(body)
	if err != nil {
		return fmt.Errorf("读取响应: %w", err)
	}
	if len(text) > MaxListBytes {
		return fmt.Errorf("超过单订阅体积上限 %d 字节", MaxListBytes)
	}
	lines := countRuleLines(string(text))
	if lines < MinListLines {
		return fmt.Errorf("非注释行数 %d 低于最小值 %d，疑似坏响应", lines, MinListLines)
	}
	if old.Lines > 0 && lines*100 < old.Lines*(100-ShrinkWarnPct) {
		m.log.Warn("订阅 ", s.Name, " 行数从 ", old.Lines, " 收缩到 ", lines, "（>50%），请核对订阅源")
	}

	// 原子落盘：临时文件（同目录保证同分区）+ 改名替换。
	tmp, err := os.CreateTemp(m.dir, ".sub-*")
	if err != nil {
		return fmt.Errorf("创建临时文件: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if _, err := tmp.WriteString(string(text)); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("写入: %w", err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpName, file); err != nil {
		cleanup()
		return fmt.Errorf("原子替换: %w", err)
	}

	next := meta{
		ETag:         resp.Header.Get("ETag"),
		LastModified: resp.Header.Get("Last-Modified"),
		FetchedAt:    m.nowFunc(),
		Lines:        lines,
	}
	if mb, err := json.Marshal(next); err == nil {
		_ = os.WriteFile(file+".meta.json", mb, 0o644)
	}
	m.log.Info("订阅已更新 ", s.Name, ": ", lines, " 行, ", len(text), " 字节")
	return nil
}

// countRuleLines 统计非空、非注释（!/# 开头）行数。
func countRuleLines(text string) int {
	n := 0
	for _, ln := range strings.Split(text, "\n") {
		s := strings.TrimSpace(ln)
		if s == "" || strings.HasPrefix(s, "!") || strings.HasPrefix(s, "#") {
			continue
		}
		n++
	}
	return n
}
