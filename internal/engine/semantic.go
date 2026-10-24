package engine

import "github.com/SYTKILLER/Dragnet/internal/verdict"

// SemanticFixture 返回编码三 realm 语义契约的标准夹具规则。
// go test 与 cmd/dragnetctl -selftest 共用；任何引擎实现都必须通过
// SemanticCases 的全部用例（M0-3 跨引擎一致性测试集的种子）。
func SemanticFixture() NamedRules {
	return NamedRules{
		Name: "semantic-fixture",
		Text: `||ads.example.com^
@@||allow.example.com^
||both.example.com^
@@||both.example.com^
||imp.example.com^$important
@@||imp.example.com^
0.0.0.0 hosts.example.com
127.0.0.1 hosts6.example.com
||path.example.com^/ads/
##.cosmetic-class
||rewrite.example.com^$dnsrewrite=1.2.3.4
||up.example.com^
@@||sub.up.example.com^$important
`,
	}
}

// SemanticCase 是一条语义契约期望。
type SemanticCase struct {
	Domain string
	Want   verdict.Action
}

// SemanticCases 返回语义契约的全部期望用例。
// 分组约定：新增用例按证据维度/优先级层次排列，便于换引擎验收时定位差异。
func SemanticCases() []SemanticCase {
	return []SemanticCase{
		// 三 realm 优先级：普通阻断 < @@ 例外 < $important 阻断。
		{Domain: "ads.example.com", Want: verdict.ActionBlock},     // 基础阻断
		{Domain: "sub.ads.example.com", Want: verdict.ActionBlock}, // ||domain^ 覆盖子域
		{Domain: "allow.example.com", Want: verdict.ActionAllow},   // @@ 例外
		{Domain: "both.example.com", Want: verdict.ActionAllow},    // 例外压过普通阻断
		{Domain: "imp.example.com", Want: verdict.ActionBlock},     // $important 压过例外
		// 例外与 $important 的反向组合：例外是 $important 时同样压过普通阻断。
		{Domain: "sub.up.example.com", Want: verdict.ActionAllow},
		// hosts 文件式规则（v4/v6 前缀形态）：视为阻断。
		{Domain: "hosts.example.com", Want: verdict.ActionBlock},
		{Domain: "hosts6.example.com", Want: verdict.ActionBlock},
		// DNS 级天然不命中/不参与语义的规则类别。
		{Domain: "path.example.com", Want: verdict.ActionNoMatch},    // 带路径规则忽略
		{Domain: "rewrite.example.com", Want: verdict.ActionNoMatch}, // $dnsrewrite 改写类不在语义内
		// 归一化与 fail-open。
		{Domain: "ADS.EXAMPLE.COM.", Want: verdict.ActionBlock}, // 大写+尾点归一化后命中
		{Domain: "neutral.example.com", Want: verdict.ActionNoMatch},
		{Domain: "", Want: verdict.ActionNoMatch}, // 无域名证据 fail-open
	}
}
