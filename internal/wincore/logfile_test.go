//go:build windows

package wincore

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"testing"
)

func TestSetupLogFileRotate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dragnetd.log")

	// 第一轮：写小日志，不触发轮转。
	restore, err := setupLogFile(path)
	if err != nil {
		t.Fatalf("setupLogFile: %v", err)
	}
	log.Print("第一轮")
	restore()

	b, err := os.ReadFile(path)
	if err != nil || !bytes.Contains(b, []byte("第一轮")) {
		t.Fatalf("日志未写入文件: %v", err)
	}

	// 第二轮：把文件膨胀到阈值之上，再开日志应轮转为 .1。
	if err := os.WriteFile(path, make([]byte, MaxLogBytes+1), 0o644); err != nil {
		t.Fatal(err)
	}
	restore2, err := setupLogFile(path)
	if err != nil {
		t.Fatalf("second setupLogFile: %v", err)
	}
	log.Print("第二轮")
	restore2()

	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatalf("旧日志未轮转为 .1: %v", err)
	}
	b2, _ := os.ReadFile(path)
	if bytes.Contains(b2, []byte("第一轮")) {
		t.Fatalf("新文件不应包含轮转前的内容")
	}
	if !bytes.Contains(b2, []byte("第二轮")) {
		t.Fatalf("新文件应包含本轮日志")
	}
}
