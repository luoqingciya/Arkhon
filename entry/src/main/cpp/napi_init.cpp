// T2 NAPI probe: load the Go c-shared .so (libhellogo.so) and call its C ABI.
// T3 Gate-D: additionally load libclash.so (real mihomo kernel wrapper) and drive
// version / start / stop. All .so are cross-compiled with the OHOS Go fork (TLS_GD).
#include "napi/native_api.h"
#include <dlfcn.h>
#include <string>
#include <cstdlib>

using HelloFn = char *(*)(char *);
using AddFn = int (*)(int, int);
using ProbeFn = int (*)(void);

static HelloFn g_hello = nullptr;
static AddFn g_add = nullptr;
static ProbeFn g_probe = nullptr;
static std::string g_dlerror;

// 打开 Go 编译出的 .so 并解析符号（幂等，失败返回 false）。
static bool ensureLoaded() {
    static bool tried = false;
    static bool ok = false;
    if (tried) return ok;
    tried = true;
    void *h = dlopen("libhellogo.so", RTLD_NOW);
    if (!h) {
        const char *e = dlerror();
        g_dlerror = e ? e : "dlopen failed";
        return false;
    }
    g_hello = reinterpret_cast<HelloFn>(dlsym(h, "Hello"));
    g_add = reinterpret_cast<AddFn>(dlsym(h, "Add"));
    g_probe = reinterpret_cast<ProbeFn>(dlsym(h, "ProbeNetCrypto"));
    if (!g_hello || !g_add) {
        const char *e = dlerror();
        g_dlerror = e ? e : "dlsym failed";
        return false;
    }
    // ProbeNetCrypto 为可选探针（部分内核实测产物未必导出）；缺省视为 -2（不可用）
    if (!g_probe) {
        g_dlerror = "ProbeNetCrypto not exported (optional)";
    }
    ok = true;
    return ok;
}

// loadGoHello(): run Go .so, return {loaded, hello, add, probe, err}.
static napi_value LoadGoHello(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);

    bool loaded = ensureLoaded();
    std::string hello = loaded ? std::string(g_hello(const_cast<char *>("arkhon"))) : std::string("<load-error>");
    int add = loaded ? g_add(2, 3) : -1;
    int probe = (loaded && g_probe) ? g_probe() : (loaded ? -2 : -1);

    napi_value v;
    napi_value field;
    // loaded
    napi_get_boolean(env, loaded, &v);
    napi_set_named_property(env, result, "loaded", v);
    // hello
    napi_create_string_utf8(env, hello.c_str(), NAPI_AUTO_LENGTH, &field);
    napi_set_named_property(env, result, "hello", field);
    // add
    napi_create_int32(env, add, &field);
    napi_set_named_property(env, result, "add", field);
    // probe
    napi_create_int32(env, probe, &field);
    napi_set_named_property(env, result, "probe", field);
    // err
    napi_create_string_utf8(env, g_dlerror.c_str(), NAPI_AUTO_LENGTH, &field);
    napi_set_named_property(env, result, "err", field);
    return result;
}

// ---- T3 Gate-D: real kernel (libclash.so) wrapper ----
using VerFn  = char *(*)(void);
using StartFn = char *(*)(char *, char *, char *);
using StopFn  = void (*)(void);

static void *g_clash = nullptr;
static VerFn g_clashVer = nullptr;
static StartFn g_clashStart = nullptr;
static StopFn g_clashStop = nullptr;
static std::string g_clashErr;

static bool clashEnsureLoaded() {
    static bool tried = false;
    static bool ok = false;
    if (tried) return ok;
    tried = true;
    void *h = dlopen("libclash.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();
        g_clashErr = e ? e : "dlopen libclash.so failed";
        return false;
    }
    g_clashVer   = reinterpret_cast<VerFn>(dlsym(h, "arkhon_core_version"));
    g_clashStart = reinterpret_cast<StartFn>(dlsym(h, "arkhon_core_start"));
    g_clashStop  = reinterpret_cast<StopFn>(dlsym(h, "arkhon_core_stop"));
    if (!g_clashVer || !g_clashStart) {
        const char *e = dlerror();
        g_clashErr = e ? e : "dlsym clash symbols failed";
        return false;
    }
    g_clash = h;
    ok = true;
    return ok;
}

// clashVersion(): { loaded, version, err }
static napi_value ClashVersion(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    bool loaded = clashEnsureLoaded();
    std::string version = loaded ? std::string(g_clashVer()) : std::string("<load-error>");
    napi_value field;
    napi_get_boolean(env, loaded, &field);
    napi_set_named_property(env, result, "loaded", field);
    napi_create_string_utf8(env, version.c_str(), NAPI_AUTO_LENGTH, &field);
    napi_set_named_property(env, result, "version", field);
    napi_create_string_utf8(env, g_clashErr.c_str(), NAPI_AUTO_LENGTH, &field);
    napi_set_named_property(env, result, "err", field);
    return result;
}

// clashStart(home, config, extController): { code, err }  code==0 on success
static napi_value ClashStart(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string home, cfg, ctrl;
    if (argc > 0 && args[0]) { napi_valuetype t; napi_typeof(env, args[0], &t); if (t == napi_string) { size_t n; char buf[512]; napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &n); home.assign(buf, n); } }
    if (argc > 1 && args[1]) { napi_valuetype t; napi_typeof(env, args[1], &t); if (t == napi_string) { size_t n; napi_get_value_string_utf8(env, args[1], nullptr, 0, &n); std::string b(n + 1, '\0'); napi_get_value_string_utf8(env, args[1], &b[0], n + 1, &n); b.resize(n); cfg = std::move(b); } }
    if (argc > 2 && args[2]) { napi_valuetype t; napi_typeof(env, args[2], &t); if (t == napi_string) { size_t n; char buf[64]; napi_get_value_string_utf8(env, args[2], buf, sizeof(buf), &n); ctrl.assign(buf, n); } }

    // mihomo 内核是常驻的；start 幂等：已加载则先 stop 再 start，避免二次 hub.Parse 冲突
    if (clashEnsureLoaded() && g_clash) {
        g_clashStop();
    }
    int code = -1;
    std::string err;
    if (clashEnsureLoaded()) {
        char *keep = home.empty() ? nullptr : const_cast<char *>(home.c_str());
        char *resh = g_clashStart(keep,
                                  const_cast<char *>(cfg.c_str()),
                                  const_cast<char *>(ctrl.c_str()));
        if (resh) {
            err = std::string(resh);
            code = -2;
            std::free(resh);
        } else {
            code = 0;
        }
    } else {
        err = g_clashErr;
    }

    napi_value result;
    napi_create_object(env, &result);
    napi_value field;
    napi_create_int32(env, code, &field);
    napi_set_named_property(env, result, "code", field);
    napi_create_string_utf8(env, err.c_str(), NAPI_AUTO_LENGTH, &field);
    napi_set_named_property(env, result, "err", field);
    return result;
}

// clashStop(): just call into kernel shutdown.
static napi_value ClashStop(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, false, &result);
    if (clashEnsureLoaded() && g_clash) {
        g_clashStop();
        napi_get_boolean(env, true, &result);
    }
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadGoHello", nullptr, LoadGoHello, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clashVersion", nullptr, ClashVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clashStart", nullptr, ClashStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clashStop", nullptr, ClashStop, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&demoModule);
}