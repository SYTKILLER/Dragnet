// Package verify 实现验证样本集的加载与断言（M4-R2）：
// 外部可见的样本文件（域名 + 期望动作 + 备注），规则加载/订阅更新后回读
// 断言 must-block / must-allow / must-nomatch，失败即报——借鉴
// android-ad-cleaner 的"结尾复查，失败不假报成功"纪律。
//
// 样本文件格式（# 与 ! 开头为注释，TSV 或多空白分隔）：
//
	//	domain<TAB>block|allow|nomatch<TAB>[备注]
package verify

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/verdict"
)

// Sample 是一条验证样本。
type Sample struct {
	Domain string
	Want   verdict.Action
	Note   string
}

// Failure 是一条断言失败。
type Failure struct {
	Sample Sample
	Got    verdict.Action
}

// LoadSamples 解析样本文件；want 大小写不敏感。
func LoadSamples(path string) ([]Sample, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []Sample
	sc := bufio.NewScanner(f)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "!") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return nil, fmt.Errorf("verify: %s:%d 格式错误（应为 域名 期望 [备注]）", path, lineNo)
		}
		var want verdict.Action
		switch strings.ToLower(fields[1]) {
		case "block":
			want = verdict.ActionBlock
		case "allow":
			want = verdict.ActionAllow
		case "nomatch":
			want = verdict.ActionNoMatch
		default:
			return nil, fmt.Errorf("verify: %s:%d 未知期望 %q（block/allow/nomatch）", path, lineNo, fields[1])
		}
		note := ""
		if len(fields) >= 3 {
			note = strings.Join(fields[2:], " ")
		}
		out = append(out, Sample{Domain: fields[0], Want: want, Note: note})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("verify: %s 没有任何样本", path)
	}
	return out, nil
}

// Check 对引擎跑全部样本，返回失败列表（空切片=全过）。
func Check(m engine.Matcher, samples []Sample) []Failure {
	var fails []Failure
	for _, s := range samples {
		if got := m.Match(&engine.Request{Domain: s.Domain, DomainBasis: verdict.BasisDNS}).Action; got != s.Want {
			fails = append(fails, Failure{Sample: s, Got: got})
		}
	}
	return fails
}
