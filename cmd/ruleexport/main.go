// ruleexport 把本项目规则资产（AdGuard/hosts 订阅、种子规则、保护清单）
// 转换为其他 app 可用的发布格式（方向2 · 最小成果）。
//
// 产物（写入 -out 目录）：
//
//	clash-classical.yaml       Clash classical 规则集（DOMAIN-SUFFIX/DOMAIN 按来源语义）
//	clash-domain.yaml          Clash.Meta behavior:domain 纯域名集（仅后缀语义域名）
//	adguard.txt                全部阻断域名统一为 ||domain^（AdGuard Home 等通用）
//	hosts                      0.0.0.0 domain
//	domains.txt                阻断域名全集（纯域名，便于二次加工）
//	allow/clash-classical.yaml 保护/例外域名（DOMAIN-SUFFIX）
//	allow/adguard.txt          保护/例外域名（@@ 语法，保留 $important）
//	manifest.json              生成时间/标签/来源统计/产物条数
//	README.md                  面向 Clash Verge Rev / mihomo / Surge / AdGuard Home 的使用说明
//
// 红线（AGENTS.md M4-R1）：本工具不内嵌任何规则数据或规则 URL，
// 全部数据经 -in/-allow 从文件读入，订阅地址由调用方以 -base-url 传入。
//
// 用法：
//
//	go run ./cmd/ruleexport \
//	    -in src1.txt,src2.txt -in rules/starter.txt \
//	    -allow rules/protected-allow.txt \
//	    -out build/rules-dist \
//	    -base-url https://example.com/rules-dist -label 2026-11-02
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/SYTKILLER/Dragnet/internal/ruleconv"
)

// 产物文件名。
const (
	nameClassical = "clash-classical.yaml"
	nameDomain    = "clash-domain.yaml"
	nameAdguard   = "adguard.txt"
	nameHosts     = "hosts"
	nameDomains   = "domains.txt"
	nameAllowDir  = "allow"
	nameManifest  = "manifest.json"
	nameReadme    = "README.md"
)

type listFlags []string

func (l *listFlags) String() string { return strings.Join(*l, ",") }

func (l *listFlags) Set(v string) error {
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			*l = append(*l, p)
		}
	}
	return nil
}

// sourceStat 是 manifest 里单个输入文件的统计。
type sourceStat struct {
	File    string `json:"file"`
	Role    string `json:"role"` // block-source（-in）或 allow-list（-allow）
	Lines   int    `json:"lines"`
	Parsed  int    `json:"parsed"`
	Blocked int    `json:"blocked"`
	Allowed int    `json:"allowed"`
	Dropped int    `json:"dropped"`
}

type mergeSummary struct {
	Blocked           int `json:"blocked"`
	Allowed           int `json:"allowed"`
	DedupRemoved      int `json:"dedup_removed"`
	ProtectedExcluded int `json:"protected_excluded"`
	PrunedRedundant   int `json:"pruned_redundant"`
}

type manifest struct {
	GeneratedAt string         `json:"generated_at"`
	Label       string         `json:"label"`
	Sources     []sourceStat   `json:"sources"`
	Summary     mergeSummary   `json:"summary"`
	Outputs     map[string]int `json:"outputs"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "ruleexport:", err)
		os.Exit(1)
	}
}

func run() error {
	var in, allow listFlags
	out := flag.String("out", "", "输出目录（必需）")
	baseURL := flag.String("base-url", "", "订阅基地址（写进产物 README 的示例 URL；为空则用相对路径示例）")
	label := flag.String("label", "", "产物标签（写进 manifest.json）")
	flag.Var(&in, "in", "输入规则文件（AdGuard/hosts 混合格式），可多次或逗号分隔")
	flag.Var(&allow, "allow", "保护/例外清单文件（@@ 语法），可多次或逗号分隔")
	flag.Parse()

	if *out == "" {
		return errors.New("缺少 -out 输出目录")
	}
	if len(in) == 0 {
		return errors.New("缺少 -in 输入规则文件")
	}

	// ---- 读取输入 ----
	type loaded struct {
		stat    sourceStat
		entries []ruleconv.Entry
	}
	var loads []loaded
	var all []ruleconv.Entry

	load := func(paths []string, role string, allowOnly bool) error {
		for _, p := range paths {
			entries, st, err := ruleconv.ParseFile(p)
			if err != nil {
				return fmt.Errorf("读取 %s: %w", p, err)
			}
			if allowOnly {
				// -allow 文件只取放行条目（保护清单语义）
				kept := entries[:0]
				for _, e := range entries {
					if e.Action == ruleconv.ActionAllow {
						kept = append(kept, e)
					}
				}
				entries = kept
			}
			loads = append(loads, loaded{
				stat: sourceStat{
					File: p, Role: role,
					Lines: st.Lines, Parsed: st.Parsed,
					Blocked: st.Blocked, Allowed: st.Allowed, Dropped: st.Dropped,
				},
				entries: entries,
			})
			all = append(all, entries...)
			fmt.Printf("<< %-52s 行 %7d  解析 %7d（阻断 %7d / 放行 %5d）丢弃 %7d\n",
				p, st.Lines, st.Parsed, st.Blocked, st.Allowed, st.Dropped)
		}
		return nil
	}
	if err := load(in, "block-source", false); err != nil {
		return err
	}
	if err := load(allow, "allow-list", true); err != nil {
		return err
	}

	// ---- 合并去重 → 保护排除 → 冗余收缩 ----
	deduped := ruleconv.Dedupe(all)
	var blocked, allowed []ruleconv.Entry
	for _, e := range deduped {
		if e.Action == ruleconv.ActionBlock {
			blocked = append(blocked, e)
		} else {
			allowed = append(allowed, e)
		}
	}
	dedupRemoved := len(all) - len(deduped)

	blocked, protectedExcluded := ruleconv.ExcludeProtected(blocked, allowed)
	blocked, prunedRedundant := ruleconv.PruneRedundant(blocked)
	warnAncestorConflict(blocked, allowed)

	fmt.Printf("== 合并：原始 %d → 去重后 %d（去 %d）→ 保护排除 %d → 冗余收缩 %d → 阻断 %d / 例外 %d\n",
		len(all), len(deduped), dedupRemoved, protectedExcluded, prunedRedundant,
		countKind(blocked, -1), len(allowed))

	// ---- 写产物 ----
	gen := time.Now().UTC().Format(time.RFC3339)
	if err := os.MkdirAll(filepath.Join(*out, nameAllowDir), 0o755); err != nil {
		return err
	}
	srcNames := make([]string, 0, len(in))
	for _, p := range in {
		srcNames = append(srcNames, filepath.Base(p))
	}
	srcJoined := strings.Join(srcNames, ", ")
	outs := map[string]int{}

	classical := make([]string, 0, len(blocked))
	suffixOnly := make([]string, 0, len(blocked))
	adguard := make([]string, 0, len(blocked))
	hosts := make([]string, 0, len(blocked))
	domains := make([]string, 0, len(blocked))
	nSuffix, nExact := 0, 0
	for _, e := range blocked {
		switch e.Kind {
		case ruleconv.KindSuffix:
			nSuffix++
			classical = append(classical, "- DOMAIN-SUFFIX,"+e.Domain)
			suffixOnly = append(suffixOnly, "- "+e.Domain)
		case ruleconv.KindExact:
			nExact++
			classical = append(classical, "- DOMAIN,"+e.Domain)
		}
		adguard = append(adguard, "||"+e.Domain+"^")
		hosts = append(hosts, "0.0.0.0 "+e.Domain)
		domains = append(domains, e.Domain)
	}

	yamlHead := []string{
		"# 罗网 Dragnet 规则订阅（rules-dist）",
		"# generated_at: " + gen,
		"# label: " + *label,
		"# sources: " + srcJoined,
		"# 本文件由 cmd/ruleexport 自动生成，请勿手改。",
	}
	write := func(rel string, lines []string, ruleCount int) error {
		if err := writeFile(filepath.Join(*out, rel), lines); err != nil {
			return fmt.Errorf("写 %s: %w", rel, err)
		}
		outs[rel] = ruleCount
		return nil
	}

	if err := write(nameClassical, append(append(append([]string{}, yamlHead...),
		[]string{
			fmt.Sprintf("# blocked: %d（suffix %d / exact %d）", len(blocked), nSuffix, nExact),
			"# behavior: classical, format: yaml",
			"payload:",
		}...), classical...), len(classical)); err != nil {
		return err
	}
	if err := write(nameDomain, append(append(append([]string{}, yamlHead...),
		[]string{
			fmt.Sprintf("# blocked(suffix 语义): %d；hosts 来源的精确语义域名不进本文件（只进 classical），避免语义放大", nSuffix),
			"# behavior: domain, format: yaml",
			"payload:",
		}...), suffixOnly...), len(suffixOnly)); err != nil {
		return err
	}
	if err := write(nameAdguard, append([]string{
		"! 罗网 Dragnet 规则订阅（rules-dist）",
		"! generated_at: " + gen,
		"! label: " + *label,
		"! sources: " + srcJoined,
		fmt.Sprintf("! blocked: %d", len(blocked)),
		"! 本文件由 cmd/ruleexport 自动生成，请勿手改。",
	}, adguard...), len(adguard)); err != nil {
		return err
	}
	if err := write(nameHosts, append([]string{
		"# 罗网 Dragnet 规则订阅（rules-dist）",
		"# generated_at: " + gen,
		"# label: " + *label,
		fmt.Sprintf("# blocked: %d", len(blocked)),
		"# 本文件由 cmd/ruleexport 自动生成，请勿手改。",
	}, hosts...), len(hosts)); err != nil {
		return err
	}
	if err := write(nameDomains, domains, len(domains)); err != nil { // 纯域名清单，无注释头
		return err
	}

	allowClash := make([]string, 0, len(allowed))
	allowAdguard := make([]string, 0, len(allowed))
	for _, e := range allowed {
		allowClash = append(allowClash, "- DOMAIN-SUFFIX,"+e.Domain)
		rule := "@@||" + e.Domain + "^"
		if e.Important {
			rule += "$important"
		}
		allowAdguard = append(allowAdguard, rule)
	}
	if err := write(nameAllowDir+"/"+nameClassical,
		append(append(append([]string{}, yamlHead...),
			[]string{
				fmt.Sprintf("# allow(保护/例外): %d", len(allowed)),
				"# behavior: classical, format: yaml（务必放在阻断规则之前）",
				"payload:",
			}...), allowClash...), len(allowClash)); err != nil {
		return err
	}
	if err := write(nameAllowDir+"/"+nameAdguard, append([]string{
		"! 罗网 Dragnet 规则订阅（rules-dist）— 保护/例外清单",
		"! generated_at: " + gen,
		fmt.Sprintf("! allow: %d", len(allowed)),
		"! 本文件由 cmd/ruleexport 自动生成，请勿手改。",
	}, allowAdguard...), len(allowAdguard)); err != nil {
		return err
	}

	// ---- manifest 与 README ----
	m := &manifest{
		GeneratedAt: gen,
		Label:       *label,
		Sources:     make([]sourceStat, 0, len(loads)),
		Summary: mergeSummary{
			Blocked:           len(blocked),
			Allowed:           len(allowed),
			DedupRemoved:      dedupRemoved,
			ProtectedExcluded: protectedExcluded,
			PrunedRedundant:   prunedRedundant,
		},
		Outputs: outs,
	}
	for _, ld := range loads {
		m.Sources = append(m.Sources, ld.stat)
	}
	mb, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	mb = append(mb, '\n')
	if err := os.WriteFile(filepath.Join(*out, nameManifest), mb, 0o644); err != nil {
		return fmt.Errorf("写 %s: %w", nameManifest, err)
	}
	if err := os.WriteFile(filepath.Join(*out, nameReadme),
		[]byte(distReadme(m, *baseURL, srcJoined)), 0o644); err != nil {
		return fmt.Errorf("写 %s: %w", nameReadme, err)
	}

	fmt.Printf("== 产物已写入 %s（阻断 %d / 例外 %d；manifest 与 README 已生成）\n", *out, len(blocked), len(allowed))
	return nil
}

// countKind 统计指定语义条数；want<0 表示全部。
func countKind(entries []ruleconv.Entry, want ruleconv.Kind) int {
	n := 0
	for _, e := range entries {
		if want < 0 || e.Kind == want {
			n++
		}
	}
	return n
}

func writeFile(path string, lines []string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	for _, l := range lines {
		if _, err := fmt.Fprintln(w, l); err != nil {
			f.Close()
			return err
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// warnAncestorConflict 提示"保护域名处于某阻断后缀域覆盖之下"的残余风险：
// 保护排除只剔除等于/子域的阻断条目；若后缀父域本身被阻断，静态发布格式
// 又没有 $important，需要订阅端把例外规则放在阻断规则之前。仅告警不改数据。
func warnAncestorConflict(blocked, allowed []ruleconv.Entry) {
	suffix := make(map[string]bool, len(blocked))
	for _, b := range blocked {
		if b.Kind == ruleconv.KindSuffix {
			suffix[b.Domain] = true
		}
	}
	shown := 0
	for _, a := range allowed {
		d := a.Domain
		for {
			i := strings.IndexByte(d, '.')
			if i < 0 {
				break
			}
			d = d[i+1:]
			if suffix[d] {
				fmt.Fprintf(os.Stderr, "ruleexport: WARN 保护域名 %s 处于阻断后缀域 %s 覆盖之下；"+
					"发布格式无 $important，请在订阅端把例外 RULE-SET 放在阻断之前\n", a.Domain, d)
				shown++
				break
			}
		}
		if shown >= 20 {
			fmt.Fprintln(os.Stderr, "ruleexport: WARN 后续同类告警省略")
			return
		}
	}
}

// distReadme 生成发布目录的 README.md。
func distReadme(m *manifest, baseURL string, srcJoined string) string {
	u := func(file string) string {
		if baseURL == "" {
			return "./" + file
		}
		return strings.TrimRight(baseURL, "/") + "/" + file
	}
	fence := "```"
	var b strings.Builder
	fmt.Fprintf(&b, "# 罗网 Dragnet 规则订阅（rules-dist）\n\n")
	fmt.Fprintf(&b, "> generated_at: %s · label: %s\n", m.GeneratedAt, m.Label)
	fmt.Fprintf(&b, "> 本目录由 `cmd/ruleexport` 自动生成，请勿手改。")
	fmt.Fprintf(&b, "每周一 03:00 UTC 由 CI 自动重建（`.github/workflows/rules-dist.yml`），也可在 Actions 手动触发（workflow_dispatch）。\n\n")

	fmt.Fprintf(&b, "## 订阅地址\n\n")
	fmt.Fprintf(&b, "- 阻断（Clash classical）: `%s`\n", u(nameClassical))
	fmt.Fprintf(&b, "- 阻断（Clash domain）: `%s`\n", u(nameDomain))
	fmt.Fprintf(&b, "- 阻断（AdGuard）: `%s`\n", u(nameAdguard))
	fmt.Fprintf(&b, "- 阻断（hosts）: `%s`\n", u(nameHosts))
	fmt.Fprintf(&b, "- 例外/保护（Clash classical）: `%s`\n", u(nameAllowDir+"/"+nameClassical))
	fmt.Fprintf(&b, "- 例外/保护（AdGuard）: `%s`\n\n", u(nameAllowDir+"/"+nameAdguard))

	fmt.Fprintf(&b, "## 产物清单\n\n")
	fmt.Fprintf(&b, "| 文件 | 格式 | 条数 | 用途 |\n|---|---|---:|---|\n")
	fmt.Fprintf(&b, "| %s | Clash classical (yaml) | %d | mihomo / Clash Verge Rev rule-providers，DOMAIN-SUFFIX/DOMAIN 按来源语义 |\n", nameClassical, m.Outputs[nameClassical])
	fmt.Fprintf(&b, "| %s | Clash domain (yaml) | %d | mihomo behavior:domain 纯域名集（仅后缀语义，性能更好） |\n", nameDomain, m.Outputs[nameDomain])
	fmt.Fprintf(&b, "| %s | AdGuard | %d | AdGuard Home / AdGuard 客户端「DNS 拦截列表」 |\n", nameAdguard, m.Outputs[nameAdguard])
	fmt.Fprintf(&b, "| %s | hosts | %d | 系统/路由器 hosts（精确匹配语义） |\n", nameHosts, m.Outputs[nameHosts])
	fmt.Fprintf(&b, "| %s | 纯域名 | %d | 阻断域名全集，供二次加工 |\n", nameDomains, m.Outputs[nameDomains])
	fmt.Fprintf(&b, "| %s | Clash classical (yaml) | %d | 保护/例外域名（防误杀，**必须放在阻断规则之前**） |\n", nameAllowDir+"/"+nameClassical, m.Outputs[nameAllowDir+"/"+nameClassical])
	fmt.Fprintf(&b, "| %s | AdGuard | %d | 保护/例外域名（@@ 语法，保留 $important） |\n\n", nameAllowDir+"/"+nameAdguard, m.Outputs[nameAllowDir+"/"+nameAdguard])

	fmt.Fprintf(&b, "## 来源与统计\n\n")
	fmt.Fprintf(&b, "来源: %s\n\n", srcJoined)
	fmt.Fprintf(&b, "| 文件 | 角色 | 行数 | 解析 | 阻断 | 放行 | 丢弃 |\n|---|---|---:|---:|---:|---:|---:|\n")
	for _, s := range m.Sources {
		fmt.Fprintf(&b, "| `%s` | %s | %d | %d | %d | %d | %d |\n",
			filepath.Base(s.File), s.Role, s.Lines, s.Parsed, s.Blocked, s.Allowed, s.Dropped)
	}
	fmt.Fprintf(&b, "\n合并: 去重移除 %d，保护排除 %d，冗余收缩 %d，最终阻断 %d / 例外 %d（详见 `manifest.json`）。\n\n",
		m.Summary.DedupRemoved, m.Summary.ProtectedExcluded, m.Summary.PrunedRedundant, m.Summary.Blocked, m.Summary.Allowed)

	fmt.Fprintf(&b, "## Clash Verge Rev / mihomo 配置示例\n\n")
	fmt.Fprintf(&b, "%syaml\nrule-providers:\n", fence)
	fmt.Fprintf(&b, "  dragnet-allow:\n    type: http\n    behavior: classical\n    format: yaml\n")
	fmt.Fprintf(&b, "    url: %s\n    path: ./rules/dragnet-allow.yaml\n    interval: 86400\n", u(nameAllowDir+"/"+nameClassical))
	fmt.Fprintf(&b, "  dragnet-block:\n    type: http\n    behavior: classical\n    format: yaml\n")
	fmt.Fprintf(&b, "    url: %s\n    path: ./rules/dragnet-block.yaml\n    interval: 86400\n", u(nameClassical))
	fmt.Fprintf(&b, "  dragnet-block-domain:\n    type: http\n    behavior: domain\n    format: yaml\n")
	fmt.Fprintf(&b, "    url: %s\n    path: ./rules/dragnet-block-domain.yaml\n    interval: 86400\n\n", u(nameDomain))
	fmt.Fprintf(&b, "rules:\n")
	fmt.Fprintf(&b, "  - RULE-SET,dragnet-allow,DIRECT   # 例外/保护先行，防误杀\n")
	fmt.Fprintf(&b, "  - RULE-SET,dragnet-block,REJECT   # classical 版（与下面 domain 版二选一）\n")
	fmt.Fprintf(&b, "  # - RULE-SET,dragnet-block-domain,REJECT   # domain 版（mihomo 下性能更好）\n%s\n\n", fence)
	fmt.Fprintf(&b, "**顺序要求**：`dragnet-allow` 必须放在所有阻断 RULE-SET 之前——静态发布格式没有 `$important`，\n")
	fmt.Fprintf(&b, "例外规则靠先后顺序保证优先级。\n\n")

	fmt.Fprintf(&b, "## Surge / AdGuard Home\n\n")
	fmt.Fprintf(&b, "- **AdGuard Home**：设置 → 过滤器 → DNS 拦截列表 → 添加 `%s`；\n", u(nameAdguard))
	fmt.Fprintf(&b, "  再把 `%s` 加入「自定义过滤规则」来源（@@ 例外语法，优先于阻断）。\n", u(nameAllowDir+"/"+nameAdguard))
	fmt.Fprintf(&b, "- **Surge**：无原生 AdGuard 语法支持，可用 `%s` 经转换工具生成 .list，\n", u(nameDomains))
	fmt.Fprintf(&b, "  或使用支持 AdGuard 规则的模块加载 `%s`。\n", u(nameAdguard))
	fmt.Fprintf(&b, "- **hosts**：`%s` 可直接合并到系统/路由器 hosts（`0.0.0.0 domain`）。\n\n", u(nameHosts))

	fmt.Fprintf(&b, "## 更新说明\n\n")
	fmt.Fprintf(&b, "- 每周一 03:00 UTC CI 自动重建并覆盖 `rules-dist` 分支与滚动 Release（tag: `rules`）。\n")
	fmt.Fprintf(&b, "- 构建管线: `scripts/build-rules-dist.sh`（三源 + 种子规则 → 归一/去重/保护排除/冗余收缩）。\n")
	fmt.Fprintf(&b, "- 完整性自检: 阻断域名总数 < 10000 时构建直接失败（防拉到空/坏源）。\n")
	return b.String()
}
