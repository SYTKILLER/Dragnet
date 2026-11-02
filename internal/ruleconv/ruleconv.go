// Package ruleconv 把 AdGuard/hosts 混合语法规则解析、归一并转换为可发布的
// 规则资产格式（方向2：把本项目规则资产以其他 app 可用的格式发布出去）。
//
// 保守口径（宁可漏封不误封）：
//   - 阻断只保留"裸规则"||domain^（无任何 $ 选项）与 hosts 形态
//     （0.0.0.0 / 127.0.0.1 + 域名，精确匹配语义）；
//   - allow 侧接受 @@||domain^ 与 @@||domain^$important，其余选项一律丢弃；
//   - cosmetic（## 系）、正则 /.../、带路径字符（/?*=~）、IP 字面量（v4/v6）、
//     非法域名字符（只允许 [a-z0-9.-]，不含下划线）、超 253 字符、
//     空/注释行（! 或 # 开头）一律丢弃。
//
// 红线（AGENTS.md M4-R1）：本包不内嵌任何规则数据，全部规则由调用方从文件读入。
package ruleconv

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

// Kind 是域名的匹配语义：suffix（||d^，后缀匹配，含自身）或
// exact（hosts 来源，精确匹配）。导出格式必须区分二者：
// Clash classical 分别用 DOMAIN-SUFFIX/DOMAIN；Clash.Meta behavior:domain
// 纯域名集只收 suffix 语义，避免把 hosts 的精确语义放大成后缀。
type Kind int

const (
	KindSuffix Kind = iota
	KindExact
)

func (k Kind) String() string {
	if k == KindExact {
		return "exact"
	}
	return "suffix"
}

// Action 是规则动作：阻断或放行（例外/保护）。
type Action int

const (
	ActionBlock Action = iota
	ActionAllow
)

func (a Action) String() string {
	if a == ActionAllow {
		return "allow"
	}
	return "block"
}

// Entry 是一条归一化后的规则条目。
type Entry struct {
	Domain    string // 归一化域名（小写、无尾部点）
	Kind      Kind   // 匹配语义（suffix/exact），导出时按此保留来源语义
	Action    Action // 阻断/放行
	Important bool   // 仅 allow 侧：来源规则带 $important
}

// MaxDomainLen 是可接受域名最大长度（RFC 1035 全长上限）。
const MaxDomainLen = 253

// SourceStats 是单个输入文件的解析统计。
type SourceStats struct {
	File    string
	Lines   int // 物理行总数
	Parsed  int // 成功解析为条目的行（去重前）
	Blocked int // Parsed 中阻断条目数
	Allowed int // Parsed 中放行条目数
	Dropped int // 非空、非注释但被丢弃的行数
}

// ParseLine 解析单行规则。第二个返回值为 false 表示该行不产生条目
// （空行、注释、或不支持的形态——按保守口径丢弃）。
func ParseLine(line string) (Entry, bool) {
	s := strings.TrimSpace(strings.TrimPrefix(line, string(rune(0xFEFF))))
	if s == "" || isCommentHead(s) {
		return Entry{}, false
	}
	// hosts 形态优先（规则行里唯一合法的内嵌空白）
	if e, ok := parseHosts(s); ok {
		return e, true
	}
	// 行尾注释：||d^ ! 注释 / ||d^ # 注释
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		head, tail := strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+1:])
		if tail != "" && isCommentHead(tail) {
			return parseRule(head)
		}
		return Entry{}, false // 非注释的多字段行：不支持，丢弃
	}
	return parseRule(s)
}

// Normalize 域名归一：转小写、去尾部 '.'。
func Normalize(d string) string {
	return strings.TrimSuffix(strings.ToLower(d), ".")
}

// ValidDomain 判断归一化后的域名是否可安全发布：仅 [a-z0-9.-]（不含下划线），
// 各标签 1-63 字符且不以连字符开头/结尾，总长 ≤ MaxDomainLen，末段标签必须
// 含字母（同时排除 IPv4 字面量与纯数字伪 TLD；IPv6 因含 ':' 天然被字符集排除）。
func ValidDomain(d string) bool {
	if d == "" || len(d) > MaxDomainLen {
		return false
	}
	labels := strings.Split(d, ".")
	if !strings.ContainsFunc(labels[len(labels)-1], func(r rune) bool {
		return r >= 'a' && r <= 'z'
	}) {
		return false
	}
	for _, label := range labels {
		if label == "" || len(label) > 63 {
			return false
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for i := 0; i < len(label); i++ {
			c := label[i]
			if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
				return false
			}
		}
	}
	return true
}

// Parse 从流解析规则（AdGuard/hosts 混合格式），返回条目（未去重）与统计。
func Parse(r io.Reader) ([]Entry, SourceStats, error) {
	var st SourceStats
	var entries []Entry
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		st.Lines++
		line := sc.Text()
		if isBlankOrComment(line) {
			continue
		}
		if e, ok := ParseLine(line); ok {
			st.Parsed++
			if e.Action == ActionBlock {
				st.Blocked++
			} else {
				st.Allowed++
			}
			entries = append(entries, e)
		} else {
			st.Dropped++
		}
	}
	if err := sc.Err(); err != nil {
		return nil, st, fmt.Errorf("读取规则流: %w", err)
	}
	return entries, st, nil
}

// ParseFile 从文件解析规则。
func ParseFile(path string) ([]Entry, SourceStats, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, SourceStats{}, err
	}
	defer f.Close()
	entries, st, err := Parse(f)
	st.File = path
	return entries, st, err
}

// Dedupe 合并去重：同一 (action, domain) 只留一条；block 的 exact 与 suffix
// 冲突时保留 suffix（后缀语义覆盖精确语义）；allow 冲突时并集保留 important
// 标记。结果按域名稳定排序，便于产物 diff。
func Dedupe(entries []Entry) []Entry {
	type key struct {
		action Action
		domain string
	}
	m := make(map[key]Entry, len(entries))
	for _, e := range entries {
		k := key{e.Action, e.Domain}
		prev, ok := m[k]
		if !ok {
			m[k] = e
			continue
		}
		merged := prev
		if prev.Kind == KindExact && e.Kind == KindSuffix {
			merged.Kind = KindSuffix
		}
		if e.Important {
			merged.Important = true
		}
		m[k] = merged
	}
	out := make([]Entry, 0, len(m))
	for _, e := range m {
		out = append(out, e)
	}
	SortEntries(out)
	return out
}

// ExcludeProtected 剔除与保护/例外域名冲突的阻断条目：阻断域名等于保护域名、
// 或其某个父域在保护清单中（@@||p^ 的例外语义覆盖 p 及其子域），一律剔除。
// 单次全量 O(n)：对每个阻断域名沿父域链回查 allow 哈希集。allow 侧原样保留。
func ExcludeProtected(blocked, allowed []Entry) ([]Entry, int) {
	allowSet := make(map[string]bool, len(allowed))
	for _, a := range allowed {
		allowSet[a.Domain] = true
	}
	kept := make([]Entry, 0, len(blocked))
	excluded := 0
	for _, b := range blocked {
		if coveredBy(b.Domain, allowSet) {
			excluded++
			continue
		}
		kept = append(kept, b)
	}
	return kept, excluded
}

// PruneRedundant 冗余收缩（全量单遍 O(n)，哈希 + 逐级父域回查）：
// 阻断域名 X 若是清单内另一 suffix 语义域名 P 的真子域，则 X 已被
// DOMAIN-SUFFIX,P / ||P^ 覆盖，剔除；exact 语义的 P 不构成覆盖。
func PruneRedundant(blocked []Entry) ([]Entry, int) {
	suffix := make(map[string]bool, len(blocked))
	for _, b := range blocked {
		if b.Kind == KindSuffix {
			suffix[b.Domain] = true
		}
	}
	kept := make([]Entry, 0, len(blocked))
	pruned := 0
	for _, b := range blocked {
		if coveredByAncestor(b.Domain, suffix) {
			pruned++
			continue
		}
		kept = append(kept, b)
	}
	return kept, pruned
}

// SortEntries 按（域名, 语义, 动作）稳定排序，便于产物 diff。
func SortEntries(entries []Entry) {
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Domain != entries[j].Domain {
			return entries[i].Domain < entries[j].Domain
		}
		if entries[i].Kind != entries[j].Kind {
			return entries[i].Kind == KindSuffix
		}
		return entries[i].Action < entries[j].Action
	})
}

// coveredBy 判断 domain 自身或其某个父域是否在 set 中。
func coveredBy(domain string, set map[string]bool) bool {
	d := domain
	for {
		if set[d] {
			return true
		}
		i := strings.IndexByte(d, '.')
		if i < 0 {
			return false
		}
		d = d[i+1:]
	}
}

// coveredByAncestor 判断 domain 的某个真父域是否在 set 中（不含自身，
// 自身冲突由 Dedupe 处理）。
func coveredByAncestor(domain string, set map[string]bool) bool {
	d := domain
	for {
		i := strings.IndexByte(d, '.')
		if i < 0 {
			return false
		}
		d = d[i+1:]
		if set[d] {
			return true
		}
	}
}

func isCommentHead(s string) bool {
	switch s[0] {
	case '!', '#', '[':
		return true
	}
	return false
}

func isBlankOrComment(line string) bool {
	s := strings.TrimSpace(strings.TrimPrefix(line, string(rune(0xFEFF))))
	return s == "" || isCommentHead(s)
}

// parseHosts 识别 `0.0.0.0 domain` / `127.0.0.1 domain`（只认这两个 IP，
// 恰好两段字段）。hosts 域名的语义是精确匹配（KindExact）。
func parseHosts(s string) (Entry, bool) {
	fields := strings.Fields(s)
	if len(fields) != 2 {
		return Entry{}, false
	}
	if fields[0] != "0.0.0.0" && fields[0] != "127.0.0.1" {
		return Entry{}, false
	}
	d := Normalize(fields[1])
	if !ValidDomain(d) {
		return Entry{}, false
	}
	return Entry{Domain: d, Kind: KindExact, Action: ActionBlock}, true
}

// parseRule 解析单 token 规则：只收 ||domain^ 裸规则（阻断侧，无任何 $ 选项）
// 与 @@||domain^ / @@||domain^$important（放行侧）。其余形态一律丢弃。
func parseRule(t string) (Entry, bool) {
	action := ActionBlock
	if strings.HasPrefix(t, "@@") {
		action = ActionAllow
		t = t[2:]
	}
	pattern, options := t, ""
	if i := strings.IndexByte(t, '$'); i >= 0 {
		pattern, options = t[:i], t[i+1:]
	}
	if action == ActionBlock {
		if options != "" {
			return Entry{}, false // 阻断侧带任何 $ 选项（third-party/dnsrewrite/important 等）：丢弃
		}
	} else {
		switch options {
		case "":
		case "important":
		default:
			return Entry{}, false // allow 侧只接受 $important
		}
	}
	if !strings.HasPrefix(pattern, "||") {
		return Entry{}, false // 非域名锚点形态（关键词/单锚点等）：丢弃
	}
	d := Normalize(strings.TrimSuffix(pattern[2:], "^"))
	if !ValidDomain(d) {
		return Entry{}, false
	}
	e := Entry{Domain: d, Kind: KindSuffix, Action: action}
	if action == ActionAllow && options == "important" {
		e.Important = true
	}
	return e, true
}
