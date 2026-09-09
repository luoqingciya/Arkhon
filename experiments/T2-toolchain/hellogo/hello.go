// T2 toolchain probe: minimal Go c-shared .so for OpenHarmony (aarch64-linux-ohos / musl).
package main

import "C"

//export Hello
func Hello(name *C.char) *C.char {
	return C.CString("hello, " + C.GoString(name))
}

//export Add
func Add(a, b C.int) C.int {
	return a + b
}

func main() {}