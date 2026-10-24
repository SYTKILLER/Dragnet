package engine

import (
	"testing"

	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// TestSemanticContract 验证 urlfilter 实现满足 verdict 语义契约。
// 这是 M0-3 跨引擎一致性测试集的种子：替换引擎时同一夹具必须给出相同结果。
func TestSemanticContract(t *testing.T) {
	eng, err := NewURLFilter([]NamedRules{SemanticFixture()})
	if err != nil {
		t.Fatalf("构建引擎失败: %v", err)
	}
	defer func() { _ = eng.Close() }()

	for _, c := range SemanticCases() {
		got := eng.Match(&Request{Domain: c.Domain, DomainBasis: verdict.BasisDNS}).Action
		if got != c.Want {
			t.Errorf("语义契约: %q => %v, 期望 %v", c.Domain, got, c.Want)
		}
	}
}

// TestNormalization 验证域名归一化（大小写、尾随点）与命中信息完整性。
func TestNormalization(t *testing.T) {
	eng, err := NewURLFilter([]NamedRules{SemanticFixture()})
	if err != nil {
		t.Fatalf("构建引擎失败: %v", err)
	}
	defer func() { _ = eng.Close() }()

	res := eng.Match(&Request{Domain: "ADS.Example.COM.", DomainBasis: verdict.BasisDNS})
	if res.Action != verdict.ActionBlock {
		t.Errorf("大写+尾点域名未正确归一化: got %v", res.Action)
	}
	if res.List != "semantic-fixture" || res.RuleText == "" {
		t.Errorf("命中信息不完整: %+v", res)
	}
}
