package blocklist

import (
	"testing"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// TestStarterBuilds 保证内置种子始终可被引擎构建（防止手改规则文本破坏开箱能力）。
func TestStarterBuilds(t *testing.T) {
	eng, err := engine.NewURLFilter([]engine.NamedRules{{Name: StarterName, Text: Starter()}})
	if err != nil {
		t.Fatalf("种子规则构建失败: %v", err)
	}
	defer eng.Close()

	for domain, want := range map[string]verdict.Action{
		"doubleclick.net":           verdict.ActionBlock,
		"sub.googlesyndication.com": verdict.ActionBlock,
		"example.com":               verdict.ActionNoMatch, // 不存在的条目不得命中
		"":                          verdict.ActionNoMatch, // fail-open
	} {
		if got := eng.Match(&engine.Request{Domain: domain}).Action; got != want {
			t.Errorf("Match(%q) = %v, want %v", domain, got, want)
		}
	}
	if Lines() < 20 {
		t.Fatalf("种子规则行数异常少: %d", Lines())
	}
}
