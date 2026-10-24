// rulebench 是 P0-R 规则管线基准工具：用真实订阅实测构建耗时、内存与匹配吞吐，
// 为"是否需要二进制预编译"提供数据（基线 docs/tech/03 §4）。
//
// 用法：
//
//	go run ./cmd/rulebench -lists build/rules [-n 200000] [-q queries.txt]
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// defaultQueries 混合了多列表共同收录的广告/跟踪域名与研究报告中的常见正常域名，
// 使吞吐测试同时覆盖命中与未命中两条路径。
var defaultQueries = []string{
	// 广告/跟踪（docs/research/04 精选）
	"log.snssdk.com",
	"gdt.qq.com",
	"cpro.baidu.com",
	"pos.baidu.com",
	"analytics.oceanengine.com",
	"doubleclick.net",
	"googleads.g.doubleclick.net",
	"beacon.tencent.com",
	"log-sdk.ksapisrv.com",
	"adsmind.ugdtimg.com",
	// 正常
	"www.baidu.com",
	"www.qq.com",
	"www.taobao.com",
	"example.com",
	"github.com",
	"www.bilibili.com",
	"www.zhihu.com",
	"mail.163.com",
}

func main() {
	listsDir := flag.String("lists", "build/rules", "规则目录（.txt）")
	iters := flag.Int("n", 200000, "匹配吞吐测试总次数")
	queryFile := flag.String("q", "", "探测域名文件（每行一个；缺省用内置集）")
	flag.Parse()

	srcs, err := rules.SourcesFromDir(*listsDir)
	must(err)

	named := make([]engine.NamedRules, 0, len(srcs))
	var readBytes int
	for _, s := range srcs {
		b, err := os.ReadFile(s.Path)
		if err != nil {
			must(fmt.Errorf("读取 %s: %w", s.Path, err))
		}
		readBytes += len(b)
		named = append(named, engine.NamedRules{Name: s.Name, Text: string(b)})
		fmt.Printf("加载 %-24s %10d bytes\n", s.Name, len(b))
	}

	t0 := time.Now()
	eng, err := engine.NewURLFilter(named)
	if err != nil {
		must(err)
	}
	buildTime := time.Since(t0)
	defer func() { _ = eng.Close() }()

	st := eng.Stats()
	runtime.GC()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	queries := defaultQueries
	if *queryFile != "" {
		queries = readQueryFile(*queryFile)
	}

	// 预热（含 JIT 式的首次 map/trie 访问），不计入吞吐。
	blocked := 0
	for _, q := range queries {
		if eng.Match(&engine.Request{Domain: q, DomainBasis: verdict.BasisDNS}).Action == verdict.ActionBlock {
			blocked++
		}
	}

	t1 := time.Now()
	n := 0
	for i := 0; i < *iters; i++ {
		q := queries[i%len(queries)]
		if eng.Match(&engine.Request{Domain: q, DomainBasis: verdict.BasisDNS}).Action == verdict.ActionBlock {
			n++
		}
	}
	el := time.Since(t1)

	fmt.Println("----------------------------------------")
	fmt.Printf("列表数          : %d\n", st.Lists)
	fmt.Printf("原始文本        : %.1f MB / %d 行\n", float64(st.RuleTextBytes)/(1024*1024), st.RuleLines)
	fmt.Printf("存储估算        : %.1f MB\n", float64(st.StorageEstBytes)/(1024*1024))
	fmt.Printf("构建耗时        : %v（含解析+索引）\n", buildTime)
	fmt.Printf("堆内存(HeapAlloc): %.1f MB（构建后 GC 实测）\n", float64(ms.HeapAlloc)/(1024*1024))
	fmt.Println("----------------------------------------")
	fmt.Printf("内置探测集      : %d 域名, 命中阻断 %d\n", len(queries), blocked)
	fmt.Printf("吞吐            : %d 次 / %v = %s/次, %.0f QPS, 阻断 %d\n",
		*iters, el, time.Duration(el.Nanoseconds()/int64(*iters)), float64(*iters)/el.Seconds(), n)
}

func readQueryFile(path string) []string {
	f, err := os.Open(path)
	must(err)
	defer func() { _ = f.Close() }()

	var qs []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if line := strings.TrimSpace(sc.Text()); line != "" && !strings.HasPrefix(line, "#") {
			qs = append(qs, line)
		}
	}
	must(sc.Err())
	if len(qs) == 0 {
		must(fmt.Errorf("查询文件 %s 为空", path))
	}
	return qs
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "rulebench:", err)
		os.Exit(1)
	}
}
