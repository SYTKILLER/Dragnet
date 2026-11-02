package ruleconv

import (
	"strings"
	"testing"
)

func mustParse(t *testing.T, line string) Entry {
	t.Helper()
	e, ok := ParseLine(line)
	if !ok {
		t.Fatalf("ParseLine(%q) 应成功，实际被丢弃", line)
	}
	return e
}

func mustDrop(t *testing.T, line string) {
	t.Helper()
	if e, ok := ParseLine(line); ok {
		t.Fatalf("ParseLine(%q) 应丢弃，实际得到 %+v", line, e)
	}
}

// 1. 裸规则 ||domain^：可无 ^、行尾注释、大小写/尾点归一、allow 侧与 $important。
func TestParseLineBareSuffix(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"||example.com^", "example.com"},
		{"||example.com", "example.com"},         // 可无 ^
		{"||EXAMPLE.COM^", "example.com"},        // 小写归一
		{"||example.com.^", "example.com"},       // 去尾点
		{"||example.com^ ! 行尾注释", "example.com"}, // 行尾注释
		{"||example.com^ # note", "example.com"}, // 行尾 # 注释
		{"@@||example.com^", "example.com"},      // allow 侧
		{"@@||example.com^$important", "example.com"},
	}
	for _, c := range cases {
		e := mustParse(t, c.in)
		if e.Domain != c.want {
			t.Errorf("ParseLine(%q).Domain = %q, want %q", c.in, e.Domain, c.want)
		}
		if e.Kind != KindSuffix {
			t.Errorf("ParseLine(%q).Kind = %v, want suffix", c.in, e.Kind)
		}
	}
	if e := mustParse(t, "||example.com^"); e.Action != ActionBlock {
		t.Errorf("裸规则应为 block，得到 %v", e.Action)
	}
	if e := mustParse(t, "@@||example.com^"); e.Action != ActionAllow || e.Important {
		t.Errorf("@@ 无选项应为 allow 且无 important，得到 %+v", e)
	}
	if e := mustParse(t, "@@||example.com^$important"); e.Action != ActionAllow || !e.Important {
		t.Errorf("@@…$important 应为 allow+important，得到 %+v", e)
	}
}

// 2. 带 $ 选项的行：阻断侧一律丢弃；allow 侧只收 important。
func TestParseLineWithOptionsDropped(t *testing.T) {
	for _, in := range []string{
		"||example.com^$third-party",
		"||example.com^$dnsrewrite=1.2.3.4",
		"||example.com^$important", // 阻断侧 $important 也一律丢弃
		"||example.com^$all",
		"||example.com$dnstype=AAAA",
		"@@||example.com^$third-party", // allow 侧只收 $important
		"@@||example.com^$important,third-party",
		"@@||example.com^$badoption",
	} {
		mustDrop(t, in)
	}
}

// 3. hosts 形态：只认 0.0.0.0 / 127.0.0.1，语义是精确匹配（KindExact）。
func TestParseLineHosts(t *testing.T) {
	for _, in := range []string{"0.0.0.0 ads.example.com", "127.0.0.1 ads.example.com", "0.0.0.0 ADS.Example.COM."} {
		e := mustParse(t, in)
		if e.Action != ActionBlock || e.Kind != KindExact {
			t.Errorf("ParseLine(%q) = %+v，want block+exact", in, e)
		}
	}
	if e := mustParse(t, "0.0.0.0 ADS.Example.COM."); e.Domain != "ads.example.com" {
		t.Errorf("hosts 域名应归一，得到 %q", e.Domain)
	}
	for _, in := range []string{
		"10.0.0.1 ads.example.com",  // 只认 0.0.0.0 / 127.0.0.1
		"255.255.255.255 ads.com",   // 同上
		"::1 ads.example.com",       // IPv6 不认
		"0.0.0.0 ads.example.com x", // 第三字段
		"0.0.0.0 1.2.3.4",           // 域名为 IP 字面量
		"0.0.0.0",                   // 缺域名
	} {
		mustDrop(t, in)
	}
}

// 4. 非法/不支持形态：cosmetic、正则、路径字符、下划线、IP 字面量、超长等。
func TestParseLineInvalid(t *testing.T) {
	for _, in := range []string{
		"example.org##.banner",                    // cosmetic
		"example.org#@#.banner",                   // cosmetic
		"example.org#?$div",                       // cosmetic
		"example.org#$#.x",                        // AdGuard cosmetic
		"/ads-regex/",                             // 正则
		"||example.com/path^",                     // 路径字符
		"||example.com^?a=1",                      // 路径字符
		"||example.com^=x",                        // 路径字符族（=/~）
		"||exa_mple.com^",                         // 下划线
		"||1.2.3.4^",                              // IPv4 字面量
		"||2001:db8::1^",                          // IPv6 字面量
		"|http://example.com/",                    // URL 锚点
		"keywordad",                               // 关键词（无 || 锚点）
		"|example.com|",                           // 单/双竖线锚点
		"||" + strings.Repeat("a", 250) + ".com^", // >253 字符
		"||-bad.com^",                             // 标签以连字符开头
		"||example.com..^",                        // 空标签
		"1.2.3.4 evil.com",                        // 非 0.0.0.0/127.0.0.1 的 hosts 形态
		"||example.com^ junk",                     // 非注释的多字段行
	} {
		mustDrop(t, in)
	}
}

// 5. 空/注释行不产生条目。
func TestParseLineCommentsAndBlank(t *testing.T) {
	for _, in := range []string{
		"",
		"   ",
		"\t",
		"! 注释行",
		"# hosts 风格注释",
		"[Adblock Plus 2.0]",
		"\xef\xbb\xbf! 带 BOM 的注释",
	} {
		mustDrop(t, in)
	}
}

// 6. 整流解析统计：lines/parsed/blocked/allowed/dropped 口径。
func TestParseStreamStats(t *testing.T) {
	input := strings.Join([]string{
		"! header",
		"||a.com^",
		"||b.com^$third-party", // 丢弃
		"0.0.0.0 c.com",
		"@@||d.com^",
		"# comment",
		"keywordad", // 丢弃
		"",
	}, "\n")
	entries, st, err := Parse(strings.NewReader(input))
	if err != nil {
		t.Fatal(err)
	}
	if st.Lines != 7 || st.Parsed != 3 || st.Blocked != 2 || st.Allowed != 1 || st.Dropped != 2 {
		t.Errorf("统计不符: %+v", st)
	}
	if len(entries) != 3 {
		t.Fatalf("应得 3 条条目，得到 %d", len(entries))
	}
}

// 7. 归一与去重：大小写/尾点合并，exact 与 suffix 冲突保留 suffix；
// allow 重复时并集保留 important。
func TestNormalizeAndDedupe(t *testing.T) {
	raw := []Entry{
		mustParse(t, "||Example.com^"),
		mustParse(t, "||example.com.^"),
		mustParse(t, "0.0.0.0 example.com"), // exact 被 suffix 吸收
		mustParse(t, "||sub.example.com^"),
		mustParse(t, "@@||a.com^"),
		mustParse(t, "@@||A.com^$important"),
	}
	got := Dedupe(raw)
	if len(got) != 3 {
		t.Fatalf("去重后应 3 条，得到 %d: %+v", len(got), got)
	}
	byDomain := map[string]Entry{}
	for _, e := range got {
		byDomain[e.Domain] = e
	}
	e := byDomain["example.com"]
	if e.Kind != KindSuffix || e.Action != ActionBlock {
		t.Errorf("example.com 应为 block+suffix，得到 %+v", e)
	}
	if a := byDomain["a.com"]; a.Action != ActionAllow || !a.Important {
		t.Errorf("a.com 应为 allow+important，得到 %+v", a)
	}
	if _, ok := byDomain["sub.example.com"]; !ok {
		t.Error("sub.example.com 不应被去重移除")
	}
	// 排序稳定性
	for i := 1; i < len(got); i++ {
		if got[i-1].Domain > got[i].Domain {
			t.Errorf("Dedupe 结果应按域名字典序: %v", got)
			break
		}
	}
}

// 8. 保护清单排除：等于/子域剔除，无关联保留，allow 侧不受影响。
func TestExcludeProtected(t *testing.T) {
	blocked := []Entry{
		{Domain: "tenpay.com", Kind: KindSuffix, Action: ActionBlock},
		{Domain: "pay.tenpay.com", Kind: KindSuffix, Action: ActionBlock},
		{Domain: "sub.alipaydns.com", Kind: KindExact, Action: ActionBlock},
		{Domain: "ads.example.com", Kind: KindSuffix, Action: ActionBlock},
	}
	allowed := []Entry{
		{Domain: "tenpay.com", Kind: KindSuffix, Action: ActionAllow, Important: true},
		{Domain: "alipaydns.com", Kind: KindSuffix, Action: ActionAllow, Important: true},
	}
	kept, excluded := ExcludeProtected(blocked, allowed)
	if excluded != 3 {
		t.Errorf("应剔除 3 条，实际 %d", excluded)
	}
	if len(kept) != 1 || kept[0].Domain != "ads.example.com" {
		t.Errorf("应只剩 ads.example.com，得到 %+v", kept)
	}
	// gov.cn 整域豁免
	kept2, ex2 := ExcludeProtected(
		[]Entry{{Domain: "www.some.gov.cn", Kind: KindSuffix, Action: ActionBlock}},
		[]Entry{{Domain: "gov.cn", Kind: KindSuffix, Action: ActionAllow}},
	)
	if ex2 != 1 || len(kept2) != 0 {
		t.Errorf("gov.cn 子域应被剔除，得到 kept=%+v excluded=%d", kept2, ex2)
	}
}

// 9. 冗余收缩：suffix 父覆盖剔除子（exact 条目同样被 suffix 父吸收）；
// exact 父不构成覆盖；allow 不参与收缩。
func TestPruneRedundant(t *testing.T) {
	blocked := []Entry{
		{Domain: "a.com", Kind: KindSuffix, Action: ActionBlock},
		{Domain: "sub.a.com", Kind: KindSuffix, Action: ActionBlock},
		{Domain: "deep.sub.a.com", Kind: KindExact, Action: ActionBlock}, // hosts 来源也被 suffix 父吸收
		{Domain: "b.com", Kind: KindExact, Action: ActionBlock},
		{Domain: "x.b.com", Kind: KindExact, Action: ActionBlock}, // b.com 是 exact，不构成覆盖
	}
	kept, pruned := PruneRedundant(blocked)
	if pruned != 2 {
		t.Errorf("应收缩 2 条，实际 %d", pruned)
	}
	domains := map[string]bool{}
	for _, e := range kept {
		domains[e.Domain] = true
	}
	for _, want := range []string{"a.com", "b.com", "x.b.com"} {
		if !domains[want] {
			t.Errorf("应保留 %s，得到 %+v", want, kept)
		}
	}
	if domains["sub.a.com"] || domains["deep.sub.a.com"] {
		t.Errorf("sub.a.com/deep.sub.a.com 应被收缩，得到 %+v", kept)
	}
}

// 10. ValidDomain 边界：长度 253/254、连字符、数字 TLD、下划线、空标签。
func TestValidDomain(t *testing.T) {
	valid := []string{
		"example.com",
		"a-b.cn",
		"xn--fiqs8s",
		"a.b.c.d.e",
		strings.Join([]string{strings.Repeat("a", 63), strings.Repeat("b", 63), strings.Repeat("c", 63), strings.Repeat("d", 57), "com"}, "."), // 恰好 253
	}
	invalid := []string{
		"",
		"Example.COM", // 未归一的大写
		strings.Join([]string{strings.Repeat("a", 63), strings.Repeat("b", 63), strings.Repeat("c", 63), strings.Repeat("d", 58), "com"}, "."), // 254
		strings.Repeat("a", 64) + ".com", // 单标签超 63
		"a..b",
		".example.com",
		"-a.com",
		"a-.com",
		"1.2.3.4",     // IPv4
		"example.123", // 纯数字 TLD
		"under_score.com",
		"exa mple.com",
	}
	for _, d := range valid {
		if !ValidDomain(d) {
			t.Errorf("ValidDomain(%q) 应为 true", d)
		}
	}
	for _, d := range invalid {
		if ValidDomain(d) {
			t.Errorf("ValidDomain(%q) 应为 false", d)
		}
	}
}
