package engine

import (
	"fmt"
	"strings"

	"github.com/AdguardTeam/urlfilter"
	"github.com/AdguardTeam/urlfilter/filterlist"
	"github.com/AdguardTeam/urlfilter/rules"

	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// NamedRules 是一个具名规则列表（订阅）的内存文本。
type NamedRules struct {
	Name string
	Text string
}

// URLFilterEngine 基于 AdGuard urlfilter 的 DNS 级匹配实现。
//
// v1 处置口径（规则支持矩阵初稿，docs/tech/03 §2）：
//   - 域名类网络规则（||domain^ 等）、@@ 例外、$important、hosts 规则：支持；
//   - 带路径/正则/查询参数的规则：DNS 级无 URL 上下文，天然不命中（忽略，不降级）；
//   - cosmetic 规则：加载时丢弃（IgnoreCosmetic），留给 v2 MITM 层；
//   - $dnsrewrite 等结果改写类：不在拦截器语义内，仅命中无基础规则时按 NoMatch 处理。
type URLFilterEngine struct {
	dns     *urlfilter.DNSEngine
	storage *filterlist.RuleStorage
	names   map[rules.ListID]string
	stats   Stats
}

// NewURLFilter 从若干具名规则文本构建引擎。列表 ID 从 1 起顺序分配。
func NewURLFilter(lists []NamedRules) (*URLFilterEngine, error) {
	if len(lists) == 0 {
		return nil, fmt.Errorf("engine: 至少需要一个规则列表")
	}

	fls := make([]filterlist.Interface, 0, len(lists))
	names := make(map[rules.ListID]string, len(lists))
	st := Stats{Lists: len(lists)}

	for i, l := range lists {
		id := rules.ListID(i + 1)
		names[id] = l.Name
		st.RuleTextBytes += len(l.Text)
		st.RuleLines += strings.Count(l.Text, "\n") + 1
		fls = append(fls, filterlist.NewString(&filterlist.StringConfig{
			RulesText:      l.Text,
			ID:             id,
			IgnoreCosmetic: true,
		}))
	}

	storage, err := filterlist.NewRuleStorage(fls)
	if err != nil {
		return nil, fmt.Errorf("engine: 构建规则存储: %w", err)
	}

	st.StorageEstBytes = int(storage.SizeEstimate())
	return &URLFilterEngine{
		dns:     urlfilter.NewDNSEngine(storage),
		storage: storage,
		names:   names,
		stats:   st,
	}, nil
}

// Match 实现 Matcher。域名归一化后交由 DNSEngine；无域名证据即 NoMatch（fail-open）。
func (e *URLFilterEngine) Match(req *Request) verdict.Result {
	host := req.NormalizedDomain()
	if host == "" {
		return verdict.Result{Action: verdict.ActionNoMatch, Basis: req.DomainBasis}
	}

	res, matched := e.dns.Match(host)
	if !matched || res == nil {
		return verdict.Result{Action: verdict.ActionNoMatch, Basis: req.DomainBasis}
	}

	// res.NetworkRule 已由 urlfilter 应用三 realm 优先级
	//（普通阻断 < @@ 例外 < $important 阻断）。
	if nr := res.NetworkRule; nr != nil {
		act := verdict.ActionBlock
		if nr.Whitelist {
			act = verdict.ActionAllow
		}
		return verdict.Result{
			Action:   act,
			Basis:    req.DomainBasis,
			List:     e.names[nr.GetFilterListID()],
			RuleText: nr.Text(),
		}
	}

	// hosts 文件式规则（0.0.0.0 domain）：视为阻断。
	// TODO: HostRule 未暴露 Text/ListID 访问器，命中信息暂缺。
	if len(res.HostRulesV4) > 0 || len(res.HostRulesV6) > 0 {
		return verdict.Result{
			Action: verdict.ActionBlock,
			Basis:  req.DomainBasis,
		}
	}

	// matched 但无基础规则（仅命中 $dnsrewrite/csp 等忽略类别）：视为未命中。
	return verdict.Result{Action: verdict.ActionNoMatch, Basis: req.DomainBasis}
}

// Stats 实现 Matcher。
func (e *URLFilterEngine) Stats() Stats { return e.stats }

// Close 释放规则存储。调用后引擎不可再用于匹配。
func (e *URLFilterEngine) Close() error {
	if e.storage != nil {
		return e.storage.Close()
	}
	return nil
}
