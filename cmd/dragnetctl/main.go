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
	"github.com/SYTKILLER/Dragnet/internal/subscribe"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

func main() {
	listsDir := flag.String("lists", "build/rules", "规则目录（.txt）")
	domain := flag.String("domain", "", "查询单个域名；缺省读 stdin")
	selftest := flag.Bool("selftest", false, "运行内置语义契约自检（不加载订阅）")
	subConfig := flag.String("subscribe-config", "build/subscribe.json", "订阅配置（缺文件用内置三源）")
	update := flag.Bool("update", false, "一次性更新订阅到 -lists 目录后退出")
	verifyMode := flag.Bool("verify", false, "对样本集（-samples）断言规则引擎，失败 exit 1")
	samples := flag.String("samples", "", "验证样本文件（缺省 <lists>/verify-samples.list）")
	pipeMode := flag.String("pipe", "", "控制运行中的服务: status|blocks|allow|deny|allowlist")
	flag.Parse()

	if *selftest {
		os.Exit(selfTest())
	}

	if *verifyMode {
		sp := *samples
		if sp == "" {
			sp = defaultSamplesPath(*listsDir)
		}
		os.Exit(verifyRules(*listsDir, sp))
	}

	if *update {
		os.Exit(updateRules(*listsDir, *subConfig))
	}

	if *pipeMode != "" {
		os.Exit(pipeMain(append([]string{*pipeMode}, flag.Args()...)))
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

// updateRules 一次性订阅更新（M3 条件更新）后退出。返回进程退出码。
func updateRules(listsDir, subConfig string) int {
	cfg, err := subscribe.LoadConfig(subConfig)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dragnetctl:", err)
		return 1
	}
	if err := os.MkdirAll(listsDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "dragnetctl:", err)
		return 1
	}
	var h rules.Holder
	m := subscribe.NewManager(listsDir, cfg, func() error {
		srcs, err := rules.SourcesFromDir(listsDir)
		if err != nil {
			return err
		}
		return h.Load(srcs)
	}, updateLogger{})
	res := m.RefreshOnce()
	fmt.Printf("订阅更新: 更新 %d / 跳过 %d / 失败 %d\n", res.Updated, res.Skipped, res.Failed)
	if res.Failed > 0 {
		return 1
	}
	return 0
}

type updateLogger struct{}

func (updateLogger) Info(args ...any)  { fmt.Println(append([]any{"[INFO]"}, args...)...) }
func (updateLogger) Warn(args ...any)  { fmt.Println("[WARN]", fmt.Sprint(args...)) }
func (updateLogger) Error(args ...any) { fmt.Fprintln(os.Stderr, "[ERROR]", fmt.Sprint(args...)) }

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
