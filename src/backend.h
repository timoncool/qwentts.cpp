#pragma once
// backend.h: GGML backend initialization
//
// All modules use the same pattern: load all backends, take the device
// the caller names or the best available one, keep CPU as fallback. Each backend_init call returns a fresh backend
// pair with its own device context and memory pool, so independent
// qt_contexts never share allocator state and can run concurrently.
// Sharing within one pipeline (talker, predictor, codec) is done by
// passing the same BackendPair to each module.

#include "ggml-backend.h"
#include "qt-error.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#ifdef _WIN32
#    ifndef NOMINMAX
#        define NOMINMAX
#    endif
#    ifndef WIN32_LEAN_AND_MEAN
#        define WIN32_LEAN_AND_MEAN
#    endif
#    include <windows.h>
#else
#    include <dlfcn.h>
#endif

struct BackendPair {
    ggml_backend_t backend;
    ggml_backend_t cpu_backend;
    bool           has_gpu;
};

// Physical core count heuristic (logical / 2 for HT/SMT).
// Used for GGML CPU thread count: GEMM shares SIMD units across hyperthreads,
// so one thread per physical core is optimal.
static int backend_cpu_n_threads(void) {
    int n = (int) std::thread::hardware_concurrency() / 2;
    return n > 0 ? n : 1;
}

// Standalone CPU backend via Registry API (DL-safe, no ggml-cpu.h needed).
// Sets thread count via proc address since ggml_backend_cpu_device_init_backend
// ignores its params string and always defaults to GGML_DEFAULT_N_THREADS (4).
// Returns NULL on failure.
static ggml_backend_t cpu_backend_new(int n_threads) {
    ggml_backend_dev_t cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    ggml_backend_t     cpu     = NULL;
    if (cpu_dev) {
        cpu = ggml_backend_dev_init(cpu_dev, NULL);
    }
    if (!cpu) {
        cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, NULL);
    }
    if (!cpu) {
        return NULL;
    }

    ggml_backend_dev_t dev = ggml_backend_get_device(cpu);
    ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : NULL;
    if (reg) {
        auto set_fn =
            (ggml_backend_set_n_threads_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_n_threads");
        if (set_fn) {
            set_fn(cpu, n_threads);
        }
    }
    return cpu;
}

// Collapse exact consecutive duplicate ggml log lines and report the total
// count when the run ends (tames the CUDA graph capture "reused" flood).
static void qt_ggml_log(enum ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;
    // ggml may hand a line over in pieces: the pieces gather until the line
    // ends, and each whole line goes out once through qt_log, tagged, with a
    // run of identical lines collapsed into a count.
    static std::mutex  mutex;
    static std::string pending;
    static std::string last;
    static int         count = 0;

    std::lock_guard<std::mutex> lock(mutex);
    pending += text;
    size_t end;
    while ((end = pending.find('\n')) != std::string::npos) {
        const std::string line = pending.substr(0, end);
        pending.erase(0, end + 1);
        if (count > 0 && line == last) {
            count++;
            continue;
        }
        if (count > 1) {
            qt_log(QT_LOG_INFO, "[Dedup] Previous line repeated %d times total", count);
        }
        qt_log(level == GGML_LOG_LEVEL_ERROR ? QT_LOG_ERROR :
               level == GGML_LOG_LEVEL_WARN  ? QT_LOG_WARN :
                                               QT_LOG_INFO,
               "[GGML] %s", line.c_str());
        last  = line;
        count = 1;
    }
}

// Install the log callback and load every backend. Magic static: it
// happens exactly once, safe under concurrent qt_init calls.
// UTF-8 folder of the module holding this code (qwen.dll / libqwen.so, or the
// executable of a static build), empty when the system cannot tell.
static std::string backend_module_dir(void) {
    std::string path;
#ifdef _WIN32
    HMODULE module = nullptr;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&backend_module_dir), &module)) {
        std::wstring wide(32768, L'\0');
        const DWORD  n = GetModuleFileNameW(module, wide.data(), (DWORD) wide.size());
        if (n > 0 && n < wide.size()) {
            const int bytes = WideCharToMultiByte(CP_UTF8, 0, wide.data(), (int) n, nullptr, 0, nullptr, nullptr);
            path.resize(bytes);
            WideCharToMultiByte(CP_UTF8, 0, wide.data(), (int) n, path.data(), bytes, nullptr, nullptr);
        }
    }
#else
    Dl_info info{};
    if (dladdr(reinterpret_cast<void *>(&backend_module_dir), &info) && info.dli_fname) {
        path = info.dli_fname;
    }
#endif
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? std::string() : path.substr(0, slash);
}

// Loads the backend module of one registry (CPU, CUDA, Vulkan) from dir unless that backend is
// registered already (a static build registers its backends itself).
static void backend_load_module(const std::string & dir, const std::string & reg_name) {
    if (ggml_backend_reg_by_name(reg_name.c_str())) {
        return;
    }
    std::string lower = reg_name;
    for (char & c : lower) {
        c = (char) std::tolower((unsigned char) c);
    }
#ifdef _WIN32
    const std::string file = "ggml-" + lower + ".dll";
#else
    const std::string file = "libggml-" + lower + ".so";
#endif
    const std::string path = dir.empty() ? file : dir + "/" + file;
#ifdef _WIN32
    // ggml_backend_load reads the path in the ANSI code page, so a folder outside it (Cyrillic, CJK) is never found:
    // the module is loaded by its UTF-16 path and registered the way ggml registers it.
    const int    wide_len = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    std::wstring wide(wide_len > 0 ? wide_len : 0, L'\0');
    if (wide_len > 0) {
        MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wide.data(), wide_len);
    }
    HMODULE module = wide_len > 0 ? LoadLibraryExW(wide.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH) : nullptr;
    using init_fn  = ggml_backend_reg_t (*)(void);
    init_fn init   = module ? reinterpret_cast<init_fn>(GetProcAddress(module, "ggml_backend_init")) : nullptr;
    ggml_backend_reg_t reg = init ? init() : nullptr;
    if (!reg) {
        qt_log(QT_LOG_ERROR, "[Load] backend %s: cannot load %s (error %lu)", reg_name.c_str(), path.c_str(),
               (unsigned long) GetLastError());
        return;
    }
    ggml_backend_register(reg);
#else
    if (!ggml_backend_load(path.c_str())) {
        qt_log(QT_LOG_ERROR, "[Load] backend %s: cannot load %s", reg_name.c_str(), path.c_str());
    }
#endif
}

// Backends built as modules (GGML_BACKEND_DL) come from beside this library, so a host process finds the
// ggml-*.dll that ship with it. A named device (CUDA0, Vulkan0, CPU) loads the CPU backend and that
// device's own backend only, so a backend nobody runs is never loaded; no device loads every one there.
static void backend_load(const char * device) {
    static std::mutex lock;
    std::lock_guard<std::mutex> guard(lock);
    static const bool logging = (ggml_log_set(qt_ggml_log, nullptr), true);
    (void) logging;
    const std::string dir = backend_module_dir();
    if (!device) {
        static bool all = false;
        if (!all) {
            ggml_backend_load_all_from_path(dir.empty() ? nullptr : dir.c_str());
            all = true;
        }
        return;
    }
    backend_load_module(dir, "CPU");
    std::string reg = device;
    while (!reg.empty() && std::isdigit((unsigned char) reg.back())) {
        reg.pop_back();
    }
    if (!reg.empty() && reg != "CPU") {
        backend_load_module(dir, reg);
    }
}

// True when name matches a device (CUDA0, Vulkan0, MTL0, CPU...), the
// check of a --device argument. Otherwise logs the available devices on
// one self-contained line and returns false.
static bool backend_check_device(const char * name) {
    backend_load(name);
    if (ggml_backend_dev_by_name(name)) {
        return true;
    }
    std::string msg = "--device ";
    msg += name;
    msg += " not found. Available:";
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        msg += ' ';
        msg += ggml_backend_dev_name(ggml_backend_dev_get(i));
    }
    qt_log(QT_LOG_ERROR, "%s", msg.c_str());
    return false;
}

// Initialize backends: the device named by device, or the best available
// one (CUDA, Metal, Vulkan...) when device is NULL, keep CPU as fallback.
// label: log prefix, e.g. "DiT", "VAE", "LM"
// Each call returns a fresh backend pair with its own memory pool.
// Returns a BackendPair with .backend == NULL when initialisation fails;
// the caller must check this before passing it to any pipeline_*_load.
static BackendPair backend_init(const char * label, const char * device) {
    backend_load(device);

    BackendPair bp = {};
    bp.backend     = device ? ggml_backend_init_by_name(device, nullptr) : ggml_backend_init_best();
    if (!bp.backend) {
        if (device) {
            qt_log(QT_LOG_ERROR, "[Load] device %s not available", device);
        } else {
            qt_log(QT_LOG_ERROR, "[Load] no backend available");
        }
        return BackendPair{};
    }
    bool best_is_cpu = (strcmp(ggml_backend_name(bp.backend), "CPU") == 0);
    int  n_threads   = backend_cpu_n_threads();
    if (best_is_cpu) {
        ggml_backend_free(bp.backend);
        bp.backend     = cpu_backend_new(n_threads);
        bp.cpu_backend = bp.backend;
    } else {
        bp.cpu_backend = cpu_backend_new(n_threads);
    }
    if (!bp.cpu_backend) {
        qt_log(QT_LOG_ERROR, "[Load] failed to init CPU backend");
        if (bp.backend && bp.backend != bp.cpu_backend) {
            ggml_backend_free(bp.backend);
        }
        return BackendPair{};
    }
    bp.has_gpu = !best_is_cpu;
    qt_log(QT_LOG_INFO, "[Load] %s backend: %s (CPU threads: %d)", label, ggml_backend_name(bp.backend), n_threads);
    return bp;
}

// Free a backend pair returned by backend_init.
static void backend_release(ggml_backend_t backend, ggml_backend_t cpu_backend) {
    if (backend && backend != cpu_backend) {
        ggml_backend_free(backend);
    }
    if (cpu_backend) {
        ggml_backend_free(cpu_backend);
    }
}

// Create a scheduler from a backend pair.
// max_nodes: graph size hint (4096 for small models, 8192 for large)
// When a GPU is present, use its host buffer type for the CPU backend.
// Pinned memory lets the scheduler keep more ops on GPU instead of
// falling back to CPU with plain malloc.
static ggml_backend_sched_t backend_sched_new(BackendPair bp, int max_nodes) {
    ggml_backend_t             backends[2] = { bp.backend, bp.cpu_backend };
    ggml_backend_buffer_type_t bufts[2]    = { NULL, NULL };
    int                        n           = (bp.backend == bp.cpu_backend) ? 1 : 2;

    bufts[0] = ggml_backend_get_default_buffer_type(bp.backend);
    if (n == 2) {
        ggml_backend_dev_t         gpu_dev   = ggml_backend_get_device(bp.backend);
        ggml_backend_buffer_type_t host_buft = gpu_dev ? ggml_backend_dev_host_buffer_type(gpu_dev) : NULL;
        bufts[1] = host_buft ? host_buft : ggml_backend_get_default_buffer_type(bp.cpu_backend);
    }

    ggml_backend_sched_t sched = ggml_backend_sched_new(backends, bufts, n, max_nodes, false, true);
    if (!sched) {
        qt_log(QT_LOG_ERROR, "[Load] failed to create scheduler");
        return nullptr;
    }
    return sched;
}
