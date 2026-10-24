// Package engine 定义拦截内核的规则匹配层接口；语义契约见 internal/verdict。
package engine

import (
	"net/netip"
	"strings"

	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// Request 是一次连接或 DNS 查询的归一化描述。
// 不解密 TLS ⇒ 可用维度仅限域名、IP、端口、进程（基线 docs/tech/03 §2）。
type Request struct {
	// Domain 是域名证据；为空表示无域名证据（按 fail-open 放行）。
	Domain string

	// DomainBasis 标明 Domain 的来源（DNS 缓存反查 / SNI 嗅探）。
	DomainBasis verdict.Basis

	// IP 是连接目标地址（如有）。
	IP netip.Addr

	// Port 是连接目标端口。
	Port uint16

	// Process 是发起连接的进程名（Windows 等平台）；可空。
	Process string
}

// NormalizedDomain 返回归一化域名：小写、去首尾空白与尾随点。
func (r *Request) NormalizedDomain() string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(r.Domain), "."))
}

// Stats 是引擎的加载统计，供基准工具与 UI 显示。
type Stats struct {
	// Lists 是加载的规则列表数。
	Lists int

	// RuleTextBytes 是原始规则文本总字节数。
	RuleTextBytes int

	// RuleLines 是规则总行数（含注释与空行，粗计）。
	RuleLines int

	// StorageEstBytes 是引擎存储体积估算。
	StorageEstBytes int
}

// Matcher 是规则引擎的最小接口。实现方负责满足 verdict 语义契约，
// 并通过 SemanticFixture/SemanticCases 编码的一致性测试。
type Matcher interface {
	Match(req *Request) verdict.Result
	Stats() Stats
	Close() error
}
