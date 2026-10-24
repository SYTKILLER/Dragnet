// Package rules 负责规则文本的加载与引擎快照的原子切换。
//
// v1 策略（基线 docs/tech/03 §4）：保存原始文本 + 元数据；新引擎在旁路构建；
// 构建成功后原子替换，失败沿用旧引擎。二进制预编译格式延后（先实测再决定）。
package rules

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// Source 是一个规则文件来源。
type Source struct {
	Name string // 订阅名（展示用）；为零值时取文件名
	Path string // 文件路径
}

// SourcesFromDir 枚举目录下所有 .txt 规则文件（按名排序）。
func SourcesFromDir(dir string) ([]Source, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("rules: 读取目录 %s: %w", dir, err)
	}
	var srcs []Source
	for _, e := range entries {
		if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".txt") {
			continue
		}
		name := strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))
		srcs = append(srcs, Source{Name: name, Path: filepath.Join(dir, e.Name())})
	}
	if len(srcs) == 0 {
		return nil, fmt.Errorf("rules: %s 下没有 .txt 规则文件", dir)
	}
	sort.Slice(srcs, func(i, j int) bool { return srcs[i].Name < srcs[j].Name })
	return srcs, nil
}

// Holder 持有当前引擎快照：并发读无锁，替换整体原子完成。
type Holder struct {
	cur atomic.Pointer[engine.URLFilterEngine]
}

// Load 从来源构建新引擎并原子切换；构建失败时旧引擎保持不变。
// TODO(v1): 切换后立即关闭旧存储存在极小竞态窗口（在途匹配仍持有旧引用），
// 内核侧引入 RCU 式延迟释放后修复；当前由调用方保证切换时机低负载。
func (h *Holder) Load(srcs []Source) error {
	named := make([]engine.NamedRules, 0, len(srcs))
	for _, s := range srcs {
		b, err := os.ReadFile(s.Path)
		if err != nil {
			return fmt.Errorf("rules: 读取 %s: %w", s.Path, err)
		}
		name := s.Name
		if name == "" {
			name = filepath.Base(s.Path)
		}
		named = append(named, engine.NamedRules{Name: name, Text: string(b)})
	}

	eng, err := engine.NewURLFilter(named)
	if err != nil {
		return err
	}

	if old := h.cur.Swap(eng); old != nil {
		_ = old.Close()
	}
	return nil
}

// Match 以当前快照执行匹配；未加载过引擎时按 NoMatch 放行（fail-open）。
func (h *Holder) Match(req *engine.Request) verdict.Result {
	eng := h.cur.Load()
	if eng == nil {
		return verdict.Result{Action: verdict.ActionNoMatch, Basis: req.DomainBasis}
	}
	return eng.Match(req)
}

// Current 返回当前引擎快照；未加载时为 nil。
func (h *Holder) Current() *engine.URLFilterEngine {
	return h.cur.Load()
}
