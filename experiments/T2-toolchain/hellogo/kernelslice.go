// T2 step-2 probe: force net + crypto stdlib to compile for OHOS musl.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"net"
	"net/http"
	"time"
)

//export ProbeNetCrypto
//
// 触发各类网络协议 & 加密原语进入 .so，验证 TCP/UDP/TLS/crypto 相关
// stdlib 在 aarch64-ohos(musl) 下可编译、可链接。返回 0 表示编译链通过。
func ProbeNetCrypto() C_int_dummy {
	// net: TCP / UDP listener（协议族路径编译）
	go func() {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err == nil {
			_ = ln.Close()
		}
		uc, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err == nil {
			_ = uc.Close()
		}
	}()
	// crypto: ed25519 密钥 / 随机数 / tls 字段 / x509
	if _, _, err := ed25519.GenerateKey(rand.Reader); err != nil {
		return C_int_dummy(1)
	}
	var conf tls.Config
	_ = conf.CipherSuites // []uint16 字段
	_ = x509.NewCertPool()
	// serialization probe
	b, _ := json.Marshal(map[string]string{"k": "v"})
	_ = b
	// http request construction（net/http 解析路径）
	req, err := http.NewRequest("GET", "https://example.com", nil)
	if err != nil {
		return C_int_dummy(2)
	}
	req.Close = true
	_ = time.Second
	return C_int_dummy(0)
}

// C_int_dummy 用于承载 cgo 类型返回值；未直接 import "C" 时保持自洽。
type C_int_dummy int32