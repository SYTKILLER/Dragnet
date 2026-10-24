// Package verdict 定义罗网 Dragnet 的跨引擎规则匹配语义契约。
//
// 任何规则引擎实现（urlfilter / adblock-rust / 自研）都必须把内部结果
// 映射到本包的三值判定与命中信息，保证引擎可替换（基线文档 docs/tech/03 §4）。
//
// 语义要点：
//   - ActionNoMatch 表示"无法判断"：没有任何规则命中。调用方默认放行
//     （fail-open），绝不按共享 CDN 的 IP 猜测封禁。
//   - ActionAllow 表示命中例外规则（@@ 白名单），放行。
//   - ActionBlock 表示命中阻断规则。
//   - 优先级：普通阻断 < @@ 例外 < $important 阻断（uBlock 三 realm 语义）。
//     urlfilter 由 GetDNSBasicRule 保证；其他引擎必须对齐并通过一致性测试集。
//   - 域名归一化约定：小写、去尾随点；Punycode/IDNA 归一化暂未强制
//     （TODO，随规则支持矩阵定稿）。
package verdict

// Action 是三值判定：无法判断 / 阻断 / 放行。
type Action int8

const (
	// ActionNoMatch 表示无规则命中（无法判断），按默认策略放行。
	ActionNoMatch Action = iota
	// ActionBlock 表示命中阻断规则。
	ActionBlock
	// ActionAllow 表示命中例外（白名单）规则。
	ActionAllow
)

// String 实现 fmt.Stringer。
func (a Action) String() string {
	switch a {
	case ActionBlock:
		return "BLOCK"
	case ActionAllow:
		return "ALLOW"
	default:
		return "NOMATCH"
	}
}

// Basis 记录判定依据：域名证据来自 DNS 缓存反查还是 SNI 嗅探，或纯 IP / 进程匹配。
type Basis string

const (
	BasisDNS     Basis = "dns"
	BasisSNI     Basis = "sni"
	BasisIP      Basis = "ip"
	BasisProcess Basis = "process"
)

// Result 是一次匹配的完整输出，字段为空表示该维度不适用。
// 命中信息（List/RuleID/RuleText）供拦截日志回溯与一键加白使用。
type Result struct {
	Action Action

	// Basis 是本次判定所依据的证据来源。
	Basis Basis

	// List 是命中的订阅（规则列表）名称。
	List string

	// RuleID 是规则在列表内的标识（行号或哈希，由引擎实现自定）。
	RuleID string

	// RuleText 是命中规则的原文。
	RuleText string

	// Degraded 表示该规则被降级执行（如带路径的规则按域名档匹配）。
	Degraded bool
}
