//go:build !android || !cgo

// 本包主体（main.go）仅在 android&&cgo 下构建；本桩保证宿主（Windows 的
// go build ./... / go vet / 环形缓冲单测）下 package main 可编译。
package main

func main() {}
