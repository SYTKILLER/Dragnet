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
||path.example.com^/ads/
##.cosmetic-class
`,
	}
}

// SemanticCase 是一条语义契约期望。
type SemanticCase struct {
	Domain string
	Want   verdict.Action
}

// SemanticCases 返回语义契约的全部期望用例。
func SemanticCases() []SemanticCase {
	return []SemanticCase{
		{Domain: "ads.example.com", Want: verdict.ActionBlock},     // 基础阻断
		{Domain: "sub.ads.example.com", Want: verdict.ActionBlock}, // ||domain^ 覆盖子域
		{Domain: "allow.example.com", Want: verdict.ActionAllow},   // @@ 例外
		{Domain: "both.example.com", Want: verdict.ActionAllow},    // 例外压过普通阻断
		{Domain: "imp.example.com", Want: verdict.ActionBlock},     // $important 压过例外
		{Domain: "hosts.example.com", Want: verdict.ActionBlock},   // hosts 规则
		{Domain: "path.example.com", Want: verdict.ActionNoMatch},  // 带路径规则 DNS 级忽略
		{Domain: "neutral.example.com", Want: verdict.ActionNoMatch}, // 无规则命中
		{Domain: "", Want: verdict.ActionNoMatch},                    // 无域名证据 fail-open
	}
}
