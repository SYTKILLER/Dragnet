// dragnetctl 是罗网 Dragnet 的 demo CLI：加载规则订阅，逐域名输出三值判定。
// 作为 M1 Windows CLI MVP 的雏形，内核其余管线（TUN/DNS/SNI）随后接入。
//
// 用法：
//
//	go run ./cmd/dragnetctl -lists build/rules [-domain ads.example.com] [-selftest]
//
// 无 -domain 时从 stdin 逐行读取域名（空行与 # 注释跳过），Ctrl-Z/回车 结束。
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

func main() {
	listsDir := flag.String("lists", "build/rules", "规则目录（.txt）")
	domain := flag.String("domain", "", "查询单个域名；缺省读 stdin")
	selftest := flag.Bool("selftest", false, "运行内置语义契约自检（不加载订阅）")
	flag.Parse()

	if *selftest {
		os.Exit(selfTest())
	}

	srcs, err := rules.SourcesFromDir(*listsDir)
	must(err)

	var h rules.Holder
	must(h.Load(srcs))
	fmt.Fprintf(os.Stderr, "已加载 %d 个订阅: %s\n",
		h.Current().Stats().Lists, strings.Join(sourceNames(srcs), ", "))

	if *domain != "" {
		fmt.Println(formatResult(*domain, h.Match(&engine.Request{Domain: *domain, DomainBasis: verdict.BasisDNS})))
		return
	}

	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fmt.Println(formatResult(line, h.Match(&engine.Request{Domain: line, DomainBasis: verdict.BasisDNS})))
	}
	must(sc.Err())
}

func sourceNames(srcs []rules.Source) []string {
	names := make([]string, 0, len(srcs))
	for _, s := range srcs {
		names = append(names, s.Name)
	}
	return names
}

func formatResult(domain string, res verdict.Result) string {
	parts := []string{res.Action.String(), domain}
	if res.List != "" {
		parts = append(parts, "list="+res.List)
	}
	if res.RuleText != "" {
		parts = append(parts, "rule="+strconv.Quote(res.RuleText))
	}
	if res.Basis != "" {
		parts = append(parts, "basis="+string(res.Basis))
	}
	if res.Degraded {
		parts = append(parts, "degraded=true")
	}
	return strings.Join(parts, "\t")
}

// selfTest 用语义夹具验证当前引擎实现，供测试机免 go test 快速核对。
func selfTest() int {
	eng, err := engine.NewURLFilter([]engine.NamedRules{engine.SemanticFixture()})
	if err != nil {
		fmt.Fprintln(os.Stderr, "自检构建引擎失败:", err)
		return 1
	}
	defer func() { _ = eng.Close() }()

	fail := 0
	cases := engine.SemanticCases()
	for _, c := range cases {
		got := eng.Match(&engine.Request{Domain: c.Domain, DomainBasis: verdict.BasisDNS}).Action
		status := "PASS"
		if got != c.Want {
			status = "FAIL"
			fail++
		}
		fmt.Printf("%s  %-24s => %v (期望 %v)\n", status, strconv.Quote(c.Domain), got, c.Want)
	}
	if fail > 0 {
		fmt.Fprintf(os.Stderr, "自检失败：%d 条语义契约不满足\n", fail)
		return 1
	}
	fmt.Printf("语义契约自检全部通过（%d/%d）\n", len(cases), len(cases))
	return 0
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "dragnetctl:", err)
		os.Exit(1)
	}
}
