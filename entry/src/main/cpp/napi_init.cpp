// T2 NAPI probe: load the Go c-shared .so (libhellogo.so) and call its C ABI.
#include "napi/native_api.h"
#include <dlfcn.h>
#include <string>

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
    if (!g_hello || !g_add || !g_probe) {
        const char *e = dlerror();
        g_dlerror = e ? e : "dlsym failed";
        return false;
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
    int probe = loaded ? g_probe() : -1;

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

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadGoHello", nullptr, LoadGoHello, nullptr, nullptr, nullptr, napi_default, nullptr},
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