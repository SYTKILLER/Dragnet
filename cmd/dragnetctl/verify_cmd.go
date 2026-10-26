package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/SYTKILLER/Dragnet/internal/engine"
	"github.com/SYTKILLER/Dragnet/internal/rules"
	"github.com/SYTKILLER/Dragnet/internal/verify"
)

// verifyRules 实现 dragnetctl -verify（M4-R2）：加载规则目录后对样本集
// 逐条断言，任何失败 exit 1——"验证样本跑通才算完成"的验收口径。
func verifyRules(listsDir, samplesPath string) int {
	srcs, err := rules.SourcesFromDir(listsDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dragnetctl -verify:", err)
		return 1
	}
	named := make([]engine.NamedRules, 0, len(srcs))
	for _, s := range srcs {
		b, err := os.ReadFile(s.Path)
		if err != nil {
			continue
		}
		named = append(named, engine.NamedRules{Name: s.Name, Text: string(b)})
	}
	eng, err := engine.NewURLFilter(named)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dragnetctl -verify: 构建引擎:", err)
		return 1
	}
	defer eng.Close()

	samples, err := verify.LoadSamples(samplesPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dragnetctl -verify: 样本集 %s: %v（可从仓库 rules/verify-samples.list 复制）\n", samplesPath, err)
		return 1
	}
	fails := verify.Check(eng, samples)
	fmt.Printf("验证样本: %d/%d 通过\n", len(samples)-len(fails), len(samples))
	for _, f := range fails {
		note := ""
		if f.Sample.Note != "" {
			note = "（" + f.Sample.Note + "）"
		}
		fmt.Printf("  FAIL %-40s 期望 %v 得到 %v%s\n", f.Sample.Domain, f.Sample.Want, f.Got, note)
	}
	if len(fails) > 0 {
		return 1
	}
	return 0
}

// 默认样本路径：规则目录下的 verify-samples.list。
func defaultSamplesPath(listsDir string) string {
	return filepath.Join(listsDir, "verify-samples.list")
}
