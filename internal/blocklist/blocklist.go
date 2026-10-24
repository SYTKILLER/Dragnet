// Package blocklist 提供内置种子规则（M1「内置规则」要求）：无需外部订阅
// 即可开箱拦截最常见广告/跟踪域名。种子刻意保守——只收录长期稳定的
// 硬核广告域，宁可漏封不误封（详细订阅仍走 -lists 外部规则目录）。
package blocklist

import (
	_ "embed"
	"strings"
)

//go:embed starter.txt
var starterText string

// Starter 返回内置种子规则文本。
func Starter() string { return starterText }

// StarterName 是种子规则在引擎中的订阅名。
const StarterName = "dragnet-starter"

// Lines 返回非注释规则行数（统计用）。
func Lines() int {
	n := 0
	for _, ln := range strings.Split(starterText, "\n") {
		if s := strings.TrimSpace(ln); s != "" && !strings.HasPrefix(s, "!") && !strings.HasPrefix(s, "#") {
			n++
		}
	}
	return n
}
