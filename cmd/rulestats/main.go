// rulestats 对规则订阅做逐行分类统计（M0-1 规则支持矩阵定稿的数据源），
// 口径与 internal/engine 的处置注释一致：
//
//	cosmetic    —— CSS/元素隐藏（## 系），DNS 级丢弃
//	hosts       —— IP+域名 形态，视为阻断
//	domain      —— ||domain^ 基础域名规则（v1 主支持档）
//	path        —— 带路径段的域名规则，DNS 级天然不命中（忽略档）
//	regex       —— /正则/，DNS 级忽略
//	keyword     —— 无锚点子串规则（urlfilter 会按子串匹配，属降级风险档）
//	dnsrewrite  —— 结果改写类，不在拦截语义内（按 NoMatch 处理）
//	modifier    —— 其他 $ 选项规则（denyallow/ctag 等，逐项核对）
//	unclassified
//
// 用法：go run ./cmd/rulestats -lists build/rules
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var classes = []string{"domain", "path", "hosts", "cosmetic", "regex", "keyword", "dnsrewrite", "modifier", "unclassified"}

func classify(line string) string {
	s := strings.TrimSpace(line)
	if s == "" || strings.HasPrefix(s, "!") || strings.HasPrefix(s, "#") && !strings.Contains(s, "##") || strings.HasPrefix(s, "[") {
		// 注意：# 开头但含 ## 的行仍归 cosmetic 判定，见下方二次判断。
		if !strings.Contains(s, "##") {
			return ""
		}
	}

	// cosmetic：## / #@# / #?# / #$?# 等
	if strings.Contains(s, "##") || strings.Contains(s, "#@#") || strings.Contains(s, "#?#") {
		return "cosmetic"
	}
	if strings.HasPrefix(s, "/") && strings.HasSuffix(s, "/") {
		return "regex"
	}

	exc := strings.HasPrefix(s, "@@")
	body := strings.TrimPrefix(s, "@@")

	// hosts 形态：IP 开头 + 空白 + 域名
	if first := strings.Fields(body); len(first) == 2 && isIP(first[0]) {
		return "hosts"
	}

	// $ 选项拆分（$ 在规则体中首次出现处；域名规则中 $ 不会是合法字符）
	var pattern, options string
	if i := strings.IndexByte(body, '$'); i >= 0 {
		pattern, options = body[:i], body[i+1:]
	} else {
		pattern = body
	}

	if strings.Contains(options, "dnsrewrite") {
		return "dnsrewrite"
	}

	switch {
	case strings.HasPrefix(pattern, "||"):
		// 去掉结尾 ^ 后仍有 / 或 ? → 带路径段
		p := strings.TrimSuffix(pattern[2:], "^")
		if strings.ContainsAny(p, "/?") {
			return "path"
		}
		return "domain"
	case strings.HasPrefix(pattern, "|") || strings.HasSuffix(pattern, "|"):
		return "domain" // 单侧锚点仍按域名档处理
	case strings.ContainsAny(pattern, "/?*=~"):
		return "path"
	default:
		if strings.Contains(options, "important") || strings.Contains(options, "denyallow") ||
			strings.Contains(options, "ctag") || strings.Contains(options, "client") {
			return "modifier"
		}
		_ = exc
		return "keyword"
	}
}

func isIP(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 {
			return false
		}
		for _, c := range p {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

func main() {
	lists := flag.String("lists", "build/rules", "规则目录")
	flag.Parse()

	entries, err := os.ReadDir(*lists)
	if err != nil {
		fmt.Fprintln(os.Stderr, "rulestats:", err)
		os.Exit(1)
	}
	total := map[string]int{}
	fmt.Printf("%-18s %s\n", "订阅", strings.Join(classes, " "))
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".txt" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(*lists, e.Name()))
		if err != nil {
			continue
		}
		counts := map[string]int{}
		for _, ln := range strings.Split(string(b), "\n") {
			c := classify(ln)
			counts[c]++
			total[c]++
		}
		printRow(strings.TrimSuffix(e.Name(), ".txt"), counts)
	}
	fmt.Println(strings.Repeat("-", 100))
	printRow("TOTAL", total)
}

func printRow(name string, counts map[string]int) {
	cells := make([]string, 0, len(classes))
	keys := append([]string(nil), classes...)
	sort.Strings(keys)
	_ = keys
	for _, c := range classes {
		cells = append(cells, fmt.Sprintf("%8d", counts[c]))
	}
	fmt.Printf("%-18s %s\n", name, strings.Join(cells, " "))
}
