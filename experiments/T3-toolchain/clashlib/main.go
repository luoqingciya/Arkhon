// clashlib: 把 mihomo(arkhon-core) 内核封装为可被 NAPI dlopen 的 c-shared .so。
// 供 Gate-D 在手机应用进程内加载真实内核并启动（external-controller 回显 /version 作为存活信号）。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"unsafe"

	MC "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
)

// c 字符串返回约定：成功返回 NULL，失败返回需 C.free 的错误字符串（堆上）。
func cmsg(format string, a ...any) *C.char {
	return C.CString(fmt.Sprintf(format, a...))
}

//export arkhon_core_version
func arkhon_core_version() *C.char {
	return cmsg("%s build %s", MC.Version, MC.BuildTime)
}

//export arkhon_core_start
// homeDir 可为空（使用默认 C.Path.HomeDir()）；configJSON 为 mihomo YAML/JSON 配置文本。
func arkhon_core_start(home *C.char, configJSON *C.char, extController *C.char) *C.char {
	homeDir := C.GoString(home)
	cfgStr := C.GoString(configJSON)
	ctrl := C.GoString(extController)

	if homeDir != "" {
		MC.SetHomeDir(homeDir)
	}

	// 注意：传入 configBytes 时不调用 config.Init（对应 mihomo main.go 的 configString 分支），
	// 避免在沙箱内创建 config.yaml 触发权限问题；hub.Parse 以配置文本为准。
	if ctrl == "" {
		ctrl = "127.0.0.1:9097"
	}
	options := []hub.Option{hub.WithExternalController(ctrl)}

	if err := hub.Parse([]byte(cfgStr), options...); err != nil {
		return cmsg("hub.Parse: %v", err)
	}

	// 成功：返回空串而非 NULL？调用端用 dlsym 后若返回 NULL 视为成功。
	return nil
}

//export arkhon_core_stop
func arkhon_core_stop() {
	executor.Shutdown()
}

func main() {}

// 规避 cgo 对 main 包内未引用“import C”生成 C.CString 的 codegen 冲突时对程序集的符号探测：保持导出符号稳定。
var _ = unsafe.Pointer(C.CString(""))