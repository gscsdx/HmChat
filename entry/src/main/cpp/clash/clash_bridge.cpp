// NAPI bridge between the ArkTS VPN extension and the prebuilt clash core.
//
// The core (libclash_core.so, built as a Go c-shared library) is linked as a
// DT_NEEDED dependency. Its runtime uses initial-exec TLS, which the platform
// only supports for libraries loaded at process start, so this bridge never
// performs the first dlopen itself: it binds to the already-loaded instance
// with dlopen(..., RTLD_NOW | RTLD_NOLOAD) and resolves the C surface via
// dlsym. Removing the DT_NEEDED link would make the bridge fail at runtime.
//
// Contract: entry/src/main/cpp/types/libclash_bridge/Index.d.ts
// Design:   docs/integration/clash-proxy-design.md §6
//
// Threading:
//   * NAPI exports run on the ArkTS JS thread; they only validate arguments
//     and hand work to the core.
//   * init/quickStart run on napi_async_work threads and never touch JS
//     objects; results are delivered in the complete callback.
//   * The core invokes event/action/protect callbacks from its own goroutines.
//     Event and action payloads are marshalled through one threadsafe function
//     (capacity 256), protect through a separate one (capacity 64) so protect
//     can never be starved by an event flood.
//   * A protect callback blocks its goroutine until the ArkTS side acks via
//     notifyProtected(fd) or a bounded timeout expires. Delivery retries and
//     ack waits are bounded and counted; failures are logged by error code.

#include "napi/native_api.h"
#include "hilog/log.h"

#include <dlfcn.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "harlgram-clash"

namespace {

constexpr const char *kCoreLibraryName = "libclash_core.so";
constexpr const char *kEventResourceName = "clashEventSink";
constexpr const char *kProtectResourceName = "clashProtectSink";
constexpr int kEventQueueCapacity = 256;
constexpr int kProtectQueueCapacity = 64;
constexpr int kProtectDeliveryBudgetMs = 3000;
constexpr int kProtectRetryBackoffMs = 5;
constexpr int kProtectAckTimeoutMs = 3000;
// Slightly above the ArkTS RPC budget (120 s) so the RPC layer reports the
// timeout first while the async work still owns its worker thread.
constexpr int kQuickStartTimeoutMs = 130000;
constexpr int kClashRuntimeVersion = 29;  // See design §2.5: disables /proc UID scan.

// ---------------------------------------------------------------------------
// Go c-shared C surface (must match core/ exports).
// ---------------------------------------------------------------------------
using InvokeCallbackFn = void (*)(void *, const char *);
using EventListenerFn = void (*)(void *, const char *);
using ProtectFn = void (*)(void *, int);
using ResolveProcessFn = const char *(*)(void *, int, const char *, const char *, int);
using ReleaseObjectFn = void (*)(void *);
using RegisterCallbacksFn = void (*)(InvokeCallbackFn, EventListenerFn, ProtectFn,
                                     ResolveProcessFn, ReleaseObjectFn);
using SetEventListenerFn = void (*)(void *);
using InvokeActionFn = void (*)(const char *, void *);
using InitClashSyncFn = bool (*)(int, const char *);
using QuickStartFn = void (*)(const char *, const char *, const char *, void *);
using StartTunFn = bool (*)(int, void *);
using StopTunFn = void (*)();
using GetStringFn = char *(*)();
using SetStateFn = void (*)(const char *);
using FreeCStringFn = void (*)(char *);

struct CoreApi {
  void *handle = nullptr;
  RegisterCallbacksFn registerCallbacks = nullptr;
  SetEventListenerFn setEventListener = nullptr;
  InvokeActionFn invokeAction = nullptr;
  InitClashSyncFn initClashSync = nullptr;
  QuickStartFn quickStart = nullptr;
  StartTunFn startTun = nullptr;
  StopTunFn stopTun = nullptr;
  GetStringFn getRunTime = nullptr;
  GetStringFn getAndroidVpnOptions = nullptr;
  GetStringFn getCurrentProfileName = nullptr;
  SetStateFn setState = nullptr;
  FreeCStringFn freeCString = nullptr;
};

CoreApi g_core;
std::atomic<bool> g_coreReady{false};
std::mutex g_coreMutex;
// Serialises concurrent initCoreAsync calls; initClashSync mutates package-wide
// Go state (home dir, GC limits) and is not re-entrant.
std::mutex g_initMutex;

// Opaque tokens handed to the core. They are never dereferenced on this side;
// only the action token is matched directly, quickStart tokens are looked up
// in g_quickPending.
void *const kListenerToken = reinterpret_cast<void *>(0x1);
void *const kTunToken = reinterpret_cast<void *>(0x2);
void *const kActionToken = reinterpret_cast<void *>(0x3);
constexpr uintptr_t kFirstQuickToken = 0x1000;
std::atomic<uintptr_t> g_nextQuickToken{kFirstQuickToken};

// ---------------------------------------------------------------------------
// Threadsafe functions.
// ---------------------------------------------------------------------------
std::mutex g_tsfnMutex;
napi_threadsafe_function g_eventTsfn = nullptr;
napi_threadsafe_function g_protectTsfn = nullptr;
std::atomic<uint64_t> g_eventDropped{0};

// ---------------------------------------------------------------------------
// protect handshake.
// ---------------------------------------------------------------------------
enum ProtectState : int {
  kProtectPending = 0,
  kProtectAcked = 1,
  kProtectCancelled = 2,
};

struct ProtectPending {
  uint32_t epoch;
  uint32_t gen;
  int state;
};

std::mutex g_protectMutex;
std::condition_variable g_protectCv;
std::map<int, ProtectPending> g_protectPending;  // fd -> latest request
uint32_t g_protectEpoch = 0;
uint32_t g_protectGen = 0;

// Defined below; declared here because core loading registers them.
void TrampInvokeCallback(void *callback, const char *data);
void TrampEventListener(void *listener, const char *data);
void TrampProtect(void *tunInterface, int fd);
const char *TrampResolveProcess(void *tunInterface, int protocol, const char *source,
                                const char *target, int uid);
void TrampReleaseObject(void *object);

std::atomic<uint64_t> g_protectAttempts{0};
std::atomic<uint64_t> g_protectFailures{0};
std::atomic<uint64_t> g_protectTimeouts{0};
std::atomic<uint64_t> g_protectDropped{0};
std::atomic<int> g_protectLastFd{0};

// ---------------------------------------------------------------------------
// quickStart correlation.
// ---------------------------------------------------------------------------
struct QuickStartWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string init;
  std::string params;
  std::string state;
  std::string error;
  std::mutex mutex;
  std::condition_variable cv;
  bool finished = false;
  uintptr_t token = 0;
};

using QuickStartPtr = std::shared_ptr<QuickStartWork>;

struct QuickStartAsyncData {
  QuickStartPtr work;
};

std::mutex g_quickMutex;
std::map<uintptr_t, QuickStartPtr> g_quickPending;
std::atomic<bool> g_quickStartBusy{false};

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------
napi_value Undefined(napi_env env) {
  napi_value value = nullptr;
  napi_get_undefined(env, &value);
  return value;
}

napi_value ThrowTypeError(napi_env env, const char *code, const char *message) {
  napi_throw_type_error(env, code, message);
  return nullptr;
}

napi_value ThrowError(napi_env env, const char *code, const char *message) {
  napi_throw_error(env, code, message);
  return nullptr;
}

bool GetStringArg(napi_env env, napi_value value, std::string &out) {
  napi_valuetype type = napi_undefined;
  if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
    return false;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return false;
  }
  std::string buffer(length + 1, '\0');
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                 &copied) != napi_ok) {
    return false;
  }
  buffer.resize(copied);
  out = std::move(buffer);
  return true;
}

bool GetInt32Arg(napi_env env, napi_value value, int32_t &out) {
  napi_valuetype type = napi_undefined;
  if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
    return false;
  }
  return napi_get_value_int32(env, value, &out) == napi_ok;
}

bool ContainsEmbeddedNul(const std::string &value) {
  return value.find('\0') != std::string::npos;
}

void SetBoolProperty(napi_env env, napi_value object, const char *name, bool value) {
  napi_value item = nullptr;
  if (napi_get_boolean(env, value, &item) == napi_ok) {
    napi_set_named_property(env, object, name, item);
  }
}

void SetStringProperty(napi_env env, napi_value object, const char *name,
                       const std::string &value) {
  napi_value item = nullptr;
  if (napi_create_string_utf8(env, value.c_str(), value.size(), &item) == napi_ok) {
    napi_set_named_property(env, object, name, item);
  }
}

// Free a char* payload that the core allocated for one callback invocation.
// It is copied immediately; the core's buffer stays valid only for the call.
std::string CopyCoreString(const char *data) {
  return data == nullptr ? std::string() : std::string(data);
}

char *DuplicatePayload(const std::string &payload) {
  const size_t size = payload.size() + 1;
  char *copy = static_cast<char *>(std::malloc(size));
  if (copy == nullptr) {
    return nullptr;
  }
  std::memcpy(copy, payload.c_str(), size);
  return copy;
}

// ---------------------------------------------------------------------------
// Core loading and callback registration.
// ---------------------------------------------------------------------------
template <typename Fn>
bool ResolveSymbol(void *handle, const char *name, Fn &target, const char *&missing) {
  void *symbol = dlsym(handle, name);
  if (symbol == nullptr) {
    missing = name;
    return false;
  }
  target = reinterpret_cast<Fn>(symbol);
  return true;
}

// Binds to the instance already loaded through DT_NEEDED. Returns false and a
// stable error code on failure; never logs paths or configuration content.
bool EnsureCore(std::string &errorCode, std::string &missingSymbol) {
  if (g_coreReady.load(std::memory_order_acquire)) {
    return true;
  }

  std::lock_guard<std::mutex> lock(g_coreMutex);
  if (g_coreReady.load(std::memory_order_acquire)) {
    return true;
  }

  void *handle = dlopen(kCoreLibraryName, RTLD_NOW | RTLD_NOLOAD);
  if (handle == nullptr) {
    errorCode = "core_load_failed";
    OH_LOG_ERROR(LOG_APP, "core load failed code=%{public}s", errorCode.c_str());
    return false;
  }

  CoreApi api;
  api.handle = handle;
  const char *missing = nullptr;
  bool resolved = ResolveSymbol(handle, "registerCallbacks", api.registerCallbacks, missing) &&
                  ResolveSymbol(handle, "setEventListener", api.setEventListener, missing) &&
                  ResolveSymbol(handle, "invokeAction", api.invokeAction, missing) &&
                  ResolveSymbol(handle, "initClashSync", api.initClashSync, missing) &&
                  ResolveSymbol(handle, "quickStart", api.quickStart, missing) &&
                  ResolveSymbol(handle, "startTUN", api.startTun, missing) &&
                  ResolveSymbol(handle, "stopTun", api.stopTun, missing) &&
                  ResolveSymbol(handle, "getRunTime", api.getRunTime, missing) &&
                  ResolveSymbol(handle, "getAndroidVpnOptions", api.getAndroidVpnOptions, missing) &&
                  ResolveSymbol(handle, "getCurrentProfileName", api.getCurrentProfileName, missing) &&
                  ResolveSymbol(handle, "setState", api.setState, missing) &&
                  ResolveSymbol(handle, "freeCString", api.freeCString, missing);
  if (!resolved || missing != nullptr) {
    missingSymbol = missing == nullptr ? std::string() : std::string(missing);
    errorCode = "core_symbol_missing";
    OH_LOG_ERROR(LOG_APP, "core symbol missing code=%{public}s symbol=%{public}s",
                 errorCode.c_str(), missing == nullptr ? "" : missing);
    // The handle comes from the process image (RTLD_NOLOAD); do not unload it.
    return false;
  }

  g_core = api;

  g_core.registerCallbacks(TrampInvokeCallback, TrampEventListener, TrampProtect,
                           TrampResolveProcess, TrampReleaseObject);
  // A non-null listener token enables the core's event pipeline.
  g_core.setEventListener(kListenerToken);

  g_coreReady.store(true, std::memory_order_release);
  return true;
}

// ---------------------------------------------------------------------------
// Core callbacks (invoked from Go goroutines).
// ---------------------------------------------------------------------------
void DeliverEvent(const std::string &payload) {
  char *copy = DuplicatePayload(payload);
  if (copy == nullptr) {
    g_eventDropped.fetch_add(1);
    OH_LOG_WARN(LOG_APP, "event enqueue failed code=payload_alloc");
    return;
  }
  std::lock_guard<std::mutex> lock(g_tsfnMutex);
  if (g_eventTsfn == nullptr) {
    std::free(copy);
    g_eventDropped.fetch_add(1);
    return;
  }
  const napi_status status =
      napi_call_threadsafe_function(g_eventTsfn, copy, napi_tsfn_nonblocking);
  if (status != napi_ok) {
    std::free(copy);
    g_eventDropped.fetch_add(1);
    OH_LOG_WARN(LOG_APP, "event enqueue failed code=%{public}s",
                status == napi_queue_full ? "queue_full" : "tsfn_closing");
  }
}

void TrampInvokeCallback(void *callback, const char *data) {
  if (data == nullptr) {
    return;
  }
  if (callback == kActionToken) {
    // Action results are correlated by the echoed Action id on the ArkTS side.
    DeliverEvent(std::string("{\"type\":\"actionResult\",\"data\":") + data + "}");
    return;
  }

  const uintptr_t token = reinterpret_cast<uintptr_t>(callback);
  QuickStartPtr work;
  {
    std::lock_guard<std::mutex> lock(g_quickMutex);
    auto it = g_quickPending.find(token);
    if (it == g_quickPending.end()) {
      // Late delivery after the bounded wait already gave up.
      return;
    }
    work = it->second;
    g_quickPending.erase(it);
  }
  {
    std::lock_guard<std::mutex> lock(work->mutex);
    work->error = CopyCoreString(data);
    work->finished = true;
  }
  work->cv.notify_all();
}

void TrampEventListener(void *listener, const char *data) {
  (void)listener;
  if (data == nullptr) {
    return;
  }
  DeliverEvent(std::string("{\"type\":\"event\",\"data\":") + data + "}");
}

// Delivers one protect payload with a bounded retry budget.
enum class ProtectDelivery : int {
  kOk,
  kNoSink,
  kQueueFull,
  kAllocFailed,
  kSinkClosing,
};

ProtectDelivery DeliverProtect(const std::string &payload) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kProtectDeliveryBudgetMs);
  for (;;) {
    char *copy = DuplicatePayload(payload);
    if (copy == nullptr) {
      return ProtectDelivery::kAllocFailed;
    }
    napi_status status = napi_closing;
    {
      std::lock_guard<std::mutex> lock(g_tsfnMutex);
      if (g_protectTsfn == nullptr) {
        std::free(copy);
        return ProtectDelivery::kNoSink;
      }
      status = napi_call_threadsafe_function(g_protectTsfn, copy,
                                             napi_tsfn_nonblocking);
    }
    if (status == napi_ok) {
      return ProtectDelivery::kOk;
    }
    std::free(copy);
    if (status != napi_queue_full) {
      // Closing/aborted: retrying cannot succeed.
      return ProtectDelivery::kSinkClosing;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      return ProtectDelivery::kQueueFull;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(kProtectRetryBackoffMs));
  }
}

void TrampProtect(void *tunInterface, int fd) {
  (void)tunInterface;
  g_protectAttempts.fetch_add(1);
  g_protectLastFd.store(fd);

  if (fd <= 0) {
    // Never ack an invalid descriptor; count it so it is not silent.
    g_protectFailures.fetch_add(1);
    OH_LOG_WARN(LOG_APP, "protect rejected code=invalid_fd");
    return;
  }

  uint32_t epoch = 0;
  uint32_t gen = 0;
  {
    std::lock_guard<std::mutex> lock(g_protectMutex);
    epoch = g_protectEpoch;
    gen = ++g_protectGen;
    // A descriptor can be reused quickly; the newest request owns the fd slot.
    g_protectPending[fd] = ProtectPending{epoch, gen, kProtectPending};
  }

  const std::string payload =
      std::string("{\"type\":\"protect\",\"data\":{\"fd\":") + std::to_string(fd) +
      ",\"epoch\":" + std::to_string(epoch) + ",\"gen\":" + std::to_string(gen) + "}}";

  const ProtectDelivery delivery = DeliverProtect(payload);
  if (delivery != ProtectDelivery::kOk) {
    g_protectDropped.fetch_add(1);
    g_protectFailures.fetch_add(1);
    {
      std::lock_guard<std::mutex> lock(g_protectMutex);
      auto it = g_protectPending.find(fd);
      if (it != g_protectPending.end() && it->second.gen == gen) {
        g_protectPending.erase(it);
      }
    }
    const char *code = "sink_closing";
    if (delivery == ProtectDelivery::kQueueFull) {
      code = "queue_full";
    } else if (delivery == ProtectDelivery::kNoSink) {
      code = "no_sink";
    } else if (delivery == ProtectDelivery::kAllocFailed) {
      code = "payload_alloc";
    }
    OH_LOG_WARN(LOG_APP, "protect dropped code=%{public}s", code);
    return;
  }

  std::unique_lock<std::mutex> lock(g_protectMutex);
  const bool woke = g_protectCv.wait_for(
      lock, std::chrono::milliseconds(kProtectAckTimeoutMs),
      [fd, gen] {
        auto it = g_protectPending.find(fd);
        return it == g_protectPending.end() || it->second.gen != gen ||
               it->second.state != kProtectPending;
      });

  bool acked = false;
  bool cancelled = false;
  auto it = g_protectPending.find(fd);
  if (it == g_protectPending.end()) {
    cancelled = true;
  } else if (it->second.gen == gen) {
    acked = it->second.state == kProtectAcked;
    cancelled = it->second.state == kProtectCancelled;
    g_protectPending.erase(it);
  } else {
    cancelled = true;
  }

  if (acked) {
    return;
  }
  if (cancelled) {
    OH_LOG_INFO(LOG_APP, "protect cancelled code=cancelled");
    return;
  }
  if (!woke) {
    g_protectTimeouts.fetch_add(1);
    OH_LOG_WARN(LOG_APP, "protect timeout code=ack_timeout");
    return;
  }
  g_protectFailures.fetch_add(1);
  OH_LOG_WARN(LOG_APP, "protect failed code=ack_failed");
}

const char *TrampResolveProcess(void *tunInterface, int protocol, const char *source,
                                const char *target, int uid) {
  // OHOS has no per-app attribution surface in this build; see design §2.5.
  (void)tunInterface;
  (void)protocol;
  (void)source;
  (void)target;
  (void)uid;
  return nullptr;
}

void TrampReleaseObject(void *object) { (void)object; }

// ---------------------------------------------------------------------------
// JS-side callback trampolines.
// ---------------------------------------------------------------------------
void InvokeSink(napi_env env, napi_value callback, const char *json) {
  if (env == nullptr || callback == nullptr || json == nullptr) {
    return;
  }
  napi_value argument = nullptr;
  napi_value result = nullptr;
  if (napi_create_string_utf8(env, json, NAPI_AUTO_LENGTH, &argument) != napi_ok) {
    OH_LOG_WARN(LOG_APP, "sink create_string failed");
    return;
  }
  if (napi_call_function(env, callback, callback, 1, &argument, &result) != napi_ok) {
    OH_LOG_WARN(LOG_APP, "sink call failed");
  }
}

void CallJsEvent(napi_env env, napi_value callback, void *context, void *data) {
  (void)context;
  char *json = static_cast<char *>(data);
  if (json == nullptr) {
    return;
  }
  InvokeSink(env, callback, json);
  std::free(json);
}

void CallJsProtect(napi_env env, napi_value callback, void *context, void *data) {
  (void)context;
  char *json = static_cast<char *>(data);
  if (json == nullptr) {
    return;
  }
  InvokeSink(env, callback, json);
  std::free(json);
}

// ---------------------------------------------------------------------------
// Sink lifecycle.
// ---------------------------------------------------------------------------
void ReleaseSinks(const char *reason) {
  napi_threadsafe_function event = nullptr;
  napi_threadsafe_function protect = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_tsfnMutex);
    event = g_eventTsfn;
    protect = g_protectTsfn;
    g_eventTsfn = nullptr;
    g_protectTsfn = nullptr;
  }
  if (event != nullptr) {
    napi_release_threadsafe_function(event, napi_tsfn_abort);
  }
  if (protect != nullptr) {
    napi_release_threadsafe_function(protect, napi_tsfn_abort);
  }

  {
    std::lock_guard<std::mutex> lock(g_protectMutex);
    for (auto &entry : g_protectPending) {
      entry.second.state = kProtectCancelled;
    }
  }
  g_protectCv.notify_all();
  OH_LOG_INFO(LOG_APP, "sinks released reason=%{public}s", reason);
}

napi_value SetEventSink(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "setEventSink requires a callback");
  }
  napi_valuetype type = napi_undefined;
  if (napi_typeof(env, argv[0], &type) != napi_ok || type != napi_function) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "setEventSink requires a callback");
  }

  napi_value eventName = nullptr;
  napi_value protectName = nullptr;
  napi_create_string_utf8(env, kEventResourceName, NAPI_AUTO_LENGTH, &eventName);
  napi_create_string_utf8(env, kProtectResourceName, NAPI_AUTO_LENGTH, &protectName);

  napi_threadsafe_function event = nullptr;
  napi_threadsafe_function protect = nullptr;
  if (napi_create_threadsafe_function(env, argv[0], nullptr, eventName,
                                      kEventQueueCapacity, 1, nullptr, nullptr,
                                      nullptr, CallJsEvent, &event) != napi_ok) {
    return ThrowError(env, "tsfn_create_failed", "cannot create event sink");
  }
  if (napi_create_threadsafe_function(env, argv[0], nullptr, protectName,
                                      kProtectQueueCapacity, 1, nullptr, nullptr,
                                      nullptr, CallJsProtect, &protect) != napi_ok) {
    napi_release_threadsafe_function(event, napi_tsfn_abort);
    return ThrowError(env, "tsfn_create_failed", "cannot create protect sink");
  }

  napi_threadsafe_function previousEvent = nullptr;
  napi_threadsafe_function previousProtect = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_tsfnMutex);
    previousEvent = g_eventTsfn;
    previousProtect = g_protectTsfn;
    g_eventTsfn = event;
    g_protectTsfn = protect;
  }
  if (previousEvent != nullptr) {
    napi_release_threadsafe_function(previousEvent, napi_tsfn_abort);
  }
  if (previousProtect != nullptr) {
    napi_release_threadsafe_function(previousProtect, napi_tsfn_abort);
  }

  {
    // A new sink starts a new protect epoch; stale acks are logged as unknown.
    std::lock_guard<std::mutex> lock(g_protectMutex);
    g_protectEpoch++;
  }
  return Undefined(env);
}

// ---------------------------------------------------------------------------
// initCoreAsync.
// ---------------------------------------------------------------------------
struct InitCoreWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string homeDir;
  bool initialized = false;
  std::string errorCode;
};

void InitCoreExecute(napi_env env, void *data) {
  (void)env;
  auto *work = static_cast<InitCoreWork *>(data);
  std::string errorCode;
  std::string missingSymbol;
  if (!EnsureCore(errorCode, missingSymbol)) {
    work->errorCode = errorCode;
    return;
  }
  bool ok = false;
  {
    std::lock_guard<std::mutex> initLock(g_initMutex);
    ok = g_core.initClashSync != nullptr &&
         g_core.initClashSync(kClashRuntimeVersion, work->homeDir.c_str());
  }
  work->initialized = ok;
  if (!ok) {
    work->errorCode = "core_init_failed";
    OH_LOG_ERROR(LOG_APP, "core init failed code=%{public}s", "core_init_failed");
  }
}

void InitCoreComplete(napi_env env, napi_status status, void *data) {
  auto *work = static_cast<InitCoreWork *>(data);
  const napi_async_work asyncWork = work->work;
  const napi_deferred deferred = work->deferred;
  bool initialized = work->initialized;
  std::string errorCode = work->errorCode;
  if (status != napi_ok) {
    initialized = false;
    errorCode = "async_work_cancelled";
  }

  napi_value result = nullptr;
  if (napi_create_object(env, &result) != napi_ok) {
    napi_value message = nullptr;
    napi_create_string_utf8(env, "core_init_failed", NAPI_AUTO_LENGTH, &message);
    napi_reject_deferred(env, deferred, message);
  } else {
    SetBoolProperty(env, result, "initialized", initialized);
    SetBoolProperty(env, result, "isInit", initialized);
    // The version is only available through the getCoreVersion Action; until
    // that round-trip exists the contract requires an empty string, not a
    // guessed value.
    SetStringProperty(env, result, "version", std::string());
    if (!errorCode.empty()) {
      SetStringProperty(env, result, "errorCode", errorCode);
    }
    napi_resolve_deferred(env, deferred, result);
  }

  napi_delete_async_work(env, asyncWork);
  delete work;
}

napi_value InitCoreAsync(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "initCoreAsync requires a home directory");
  }
  std::string homeDir;
  if (!GetStringArg(env, argv[0], homeDir)) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "home directory must be a string");
  }

  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    return ThrowError(env, "promise_create_failed", "cannot create init promise");
  }

  if (homeDir.empty() || ContainsEmbeddedNul(homeDir)) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetBoolProperty(env, result, "initialized", false);
    SetBoolProperty(env, result, "isInit", false);
    SetStringProperty(env, result, "version", std::string());
    SetStringProperty(env, result, "errorCode", std::string("invalid_home_dir"));
    napi_resolve_deferred(env, deferred, result);
    return promise;
  }

  auto *work = new InitCoreWork();
  work->deferred = deferred;
  work->homeDir = std::move(homeDir);

  napi_value name = nullptr;
  napi_create_string_utf8(env, "clashInitCore", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name, InitCoreExecute, InitCoreComplete,
                             work, &work->work) != napi_ok) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetBoolProperty(env, result, "initialized", false);
    SetBoolProperty(env, result, "isInit", false);
    SetStringProperty(env, result, "version", std::string());
    SetStringProperty(env, result, "errorCode", std::string("async_work_failed"));
    napi_resolve_deferred(env, deferred, result);
    delete work;
    return promise;
  }
  if (napi_queue_async_work(env, work->work) != napi_ok) {
    napi_delete_async_work(env, work->work);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetBoolProperty(env, result, "initialized", false);
    SetBoolProperty(env, result, "isInit", false);
    SetStringProperty(env, result, "version", std::string());
    SetStringProperty(env, result, "errorCode", std::string("async_work_failed"));
    napi_resolve_deferred(env, deferred, result);
    delete work;
  }
  return promise;
}

// ---------------------------------------------------------------------------
// quickStartAsync.
// ---------------------------------------------------------------------------
void QuickStartExecute(napi_env env, void *data) {
  (void)env;
  auto *asyncData = static_cast<QuickStartAsyncData *>(data);
  QuickStartPtr work = asyncData->work;

  std::string errorCode;
  std::string missingSymbol;
  if (!EnsureCore(errorCode, missingSymbol)) {
    std::lock_guard<std::mutex> lock(work->mutex);
    work->error = errorCode;
    return;
  }
  if (g_core.quickStart == nullptr) {
    std::lock_guard<std::mutex> lock(work->mutex);
    work->error = "core_symbol_missing";
    return;
  }

  g_core.quickStart(work->init.c_str(), work->params.c_str(), work->state.c_str(),
                    reinterpret_cast<void *>(work->token));

  std::unique_lock<std::mutex> lock(work->mutex);
  const bool finished = work->cv.wait_for(
      lock, std::chrono::milliseconds(kQuickStartTimeoutMs),
      [&work] { return work->finished; });
  if (!finished) {
    // The Go goroutine still owns the token; erase it so a late callback is
    // dropped instead of touching a completed async work.
    work->error = "timeout";
    lock.unlock();
    std::lock_guard<std::mutex> pending(g_quickMutex);
    g_quickPending.erase(work->token);
  }
}

void QuickStartComplete(napi_env env, napi_status status, void *data) {
  auto *asyncData = static_cast<QuickStartAsyncData *>(data);
  QuickStartPtr work = asyncData->work;

  {
    std::lock_guard<std::mutex> lock(g_quickMutex);
    g_quickPending.erase(work->token);
  }

  std::string result;
  if (status != napi_ok) {
    result = "async_work_cancelled";
  } else {
    std::lock_guard<std::mutex> lock(work->mutex);
    result = work->error;
  }

  napi_value value = nullptr;
  if (napi_create_string_utf8(env, result.c_str(), result.size(), &value) != napi_ok) {
    napi_create_string_utf8(env, "async_work_failed", NAPI_AUTO_LENGTH, &value);
  }
  napi_resolve_deferred(env, work->deferred, value);
  napi_delete_async_work(env, work->work);
  g_quickStartBusy.store(false, std::memory_order_release);
  delete asyncData;
}

napi_value QuickStartAsync(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr, nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 3) {
    return ThrowTypeError(env, "ERR_INVALID_ARG",
                          "quickStartAsync requires init, params and state strings");
  }
  std::string init;
  std::string params;
  std::string state;
  if (!GetStringArg(env, argv[0], init) || !GetStringArg(env, argv[1], params) ||
      !GetStringArg(env, argv[2], state)) {
    return ThrowTypeError(env, "ERR_INVALID_ARG",
                          "quickStartAsync requires string arguments");
  }

  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    return ThrowError(env, "promise_create_failed", "cannot create quickStart promise");
  }

  auto ResolveWith = [env, deferred]() {
    napi_value value = nullptr;
    napi_create_string_utf8(env, "async_work_failed", NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, deferred, value);
  };

  if (init.empty() || params.empty() || state.empty() ||
      ContainsEmbeddedNul(init) || ContainsEmbeddedNul(params) || ContainsEmbeddedNul(state)) {
    napi_value value = nullptr;
    napi_create_string_utf8(env, "invalid_argument", NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, deferred, value);
    return promise;
  }

  bool expected = false;
  if (!g_quickStartBusy.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
    napi_value value = nullptr;
    napi_create_string_utf8(env, "busy", NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, deferred, value);
    return promise;
  }

  auto work = std::make_shared<QuickStartWork>();
  work->deferred = deferred;
  work->init = std::move(init);
  work->params = std::move(params);
  work->state = std::move(state);
  work->token = g_nextQuickToken.fetch_add(1, std::memory_order_relaxed);

  auto *asyncData = new QuickStartAsyncData{work};
  {
    std::lock_guard<std::mutex> lock(g_quickMutex);
    g_quickPending[work->token] = work;
  }

  napi_value name = nullptr;
  napi_create_string_utf8(env, "clashQuickStart", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name, QuickStartExecute, QuickStartComplete,
                             asyncData, &work->work) != napi_ok) {
    {
      std::lock_guard<std::mutex> lock(g_quickMutex);
      g_quickPending.erase(work->token);
    }
    g_quickStartBusy.store(false, std::memory_order_release);
    delete asyncData;
    ResolveWith();
    return promise;
  }
  if (napi_queue_async_work(env, work->work) != napi_ok) {
    napi_delete_async_work(env, work->work);
    {
      std::lock_guard<std::mutex> lock(g_quickMutex);
      g_quickPending.erase(work->token);
    }
    g_quickStartBusy.store(false, std::memory_order_release);
    delete asyncData;
    ResolveWith();
  }
  return promise;
}

// ---------------------------------------------------------------------------
// Short synchronous exports.
// ---------------------------------------------------------------------------
bool LooksLikeAction(const std::string &json) {
  if (json.size() < 2 || json.front() != '{' || json.back() != '}') {
    return false;
  }
  return json.find("\"id\"") != std::string::npos &&
         json.find("\"method\"") != std::string::npos;
}

napi_value InvokeAction(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "invokeAction requires a JSON string");
  }
  std::string json;
  if (!GetStringArg(env, argv[0], json)) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "action must be a JSON string");
  }
  if (!LooksLikeAction(json) || ContainsEmbeddedNul(json)) {
    return ThrowError(env, "invalid_action",
                      "action must be a JSON object containing id and method");
  }

  std::string errorCode;
  std::string missingSymbol;
  if (!EnsureCore(errorCode, missingSymbol)) {
    OH_LOG_WARN(LOG_APP, "action skipped code=%{public}s", errorCode.c_str());
    return Undefined(env);
  }
  // The core copies the string synchronously; the callback fires later.
  g_core.invokeAction(json.c_str(), kActionToken);
  return Undefined(env);
}

napi_value StartTun(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "startTun requires a descriptor");
  }
  int32_t fd = 0;
  if (!GetInt32Arg(env, argv[0], fd)) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "descriptor must be a number");
  }

  bool started = false;
  if (fd > 0) {
    {
      std::lock_guard<std::mutex> lock(g_protectMutex);
      g_protectEpoch++;
    }
    std::string errorCode;
    std::string missingSymbol;
    if (EnsureCore(errorCode, missingSymbol)) {
      started = g_core.startTun != nullptr && g_core.startTun(fd, kTunToken);
    }
  }
  if (!started) {
    // Ownership rules: never close the fd here; the core may already have
    // closed it, and a repeated close could hit a reused descriptor.
    OH_LOG_WARN(LOG_APP, "tun start failed code=%{public}s",
                fd > 0 ? "start_tun_failed" : "invalid_fd");
  }
  napi_value result = nullptr;
  napi_get_boolean(env, started, &result);
  return result;
}

napi_value StopTun(napi_env env, napi_callback_info info) {
  (void)info;
  // Unblock any in-flight protect wait before the core tears the tunnel down.
  {
    std::lock_guard<std::mutex> lock(g_protectMutex);
    for (auto &entry : g_protectPending) {
      entry.second.state = kProtectCancelled;
    }
  }
  g_protectCv.notify_all();

  if (g_coreReady.load(std::memory_order_acquire) && g_core.stopTun != nullptr) {
    g_core.stopTun();
  }
  return Undefined(env);
}

napi_value GetRunTime(napi_env env, napi_callback_info info) {
  (void)info;
  int64_t milliseconds = 0;
  if (g_coreReady.load(std::memory_order_acquire) && g_core.getRunTime != nullptr) {
    char *raw = g_core.getRunTime();
    if (raw != nullptr) {
      const long long parsed = std::strtoll(raw, nullptr, 10);
      if (parsed > 0) {
        milliseconds = static_cast<int64_t>(parsed);
      }
      g_core.freeCString(raw);
    }
  }
  napi_value result = nullptr;
  napi_create_int64(env, milliseconds, &result);
  return result;
}

std::string TakeCoreString(GetStringFn fn, FreeCStringFn freeFn) {
  if (fn == nullptr || freeFn == nullptr) {
    return std::string();
  }
  char *raw = fn();
  if (raw == nullptr) {
    return std::string();
  }
  std::string value(raw);
  freeFn(raw);
  return value;
}

napi_value GetAndroidVpnOptions(napi_env env, napi_callback_info info) {
  (void)info;
  std::string value;
  if (g_coreReady.load(std::memory_order_acquire)) {
    value = TakeCoreString(g_core.getAndroidVpnOptions, g_core.freeCString);
  }
  napi_value result = nullptr;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  return result;
}

napi_value GetCurrentProfileName(napi_env env, napi_callback_info info) {
  (void)info;
  std::string value;
  if (g_coreReady.load(std::memory_order_acquire)) {
    value = TakeCoreString(g_core.getCurrentProfileName, g_core.freeCString);
  }
  napi_value result = nullptr;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  return result;
}

napi_value SetState(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "setState requires a JSON string");
  }
  std::string json;
  if (!GetStringArg(env, argv[0], json)) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "state must be a JSON string");
  }
  if (json.empty() || json.front() != '{' || ContainsEmbeddedNul(json)) {
    return ThrowError(env, "invalid_state", "state must be a JSON object");
  }

  std::string errorCode;
  std::string missingSymbol;
  if (EnsureCore(errorCode, missingSymbol)) {
    g_core.setState(json.c_str());
  } else {
    OH_LOG_WARN(LOG_APP, "state skipped code=%{public}s", errorCode.c_str());
  }
  return Undefined(env);
}

napi_value ShutdownCore(napi_env env, napi_callback_info info) {
  (void)info;
  bool sent = false;
  if (g_coreReady.load(std::memory_order_acquire) && g_core.invokeAction != nullptr) {
    const char *action = "{\"id\":\"__core_shutdown\",\"method\":\"shutdown\"}";
    g_core.invokeAction(action, kActionToken);
    sent = true;
  } else {
    OH_LOG_WARN(LOG_APP, "shutdown skipped code=%{public}s", "core_not_loaded");
  }
  // Abort sinks so a core goroutine cannot write into a released JS handle.
  ReleaseSinks("shutdown");
  napi_value result = nullptr;
  napi_get_boolean(env, sent, &result);
  return result;
}

napi_value NotifyProtected(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "notifyProtected requires a descriptor");
  }
  int32_t fd = 0;
  if (!GetInt32Arg(env, argv[0], fd)) {
    return ThrowTypeError(env, "ERR_INVALID_ARG", "descriptor must be a number");
  }

  bool acked = false;
  {
    std::lock_guard<std::mutex> lock(g_protectMutex);
    auto it = g_protectPending.find(fd);
    if (it != g_protectPending.end() && it->second.state == kProtectPending) {
      it->second.state = kProtectAcked;
      acked = true;
    }
  }
  if (acked) {
    g_protectCv.notify_all();
  } else {
    OH_LOG_WARN(LOG_APP, "protect ack ignored code=unknown_fd");
  }
  return Undefined(env);
}

napi_value GetProtectStats(napi_env env, napi_callback_info info) {
  (void)info;
  char buffer[256];
  std::snprintf(buffer, sizeof(buffer),
                "{\"attempts\":%llu,\"failures\":%llu,\"timeouts\":%llu,"
                "\"dropped\":%llu,\"lastFd\":%d}",
                static_cast<unsigned long long>(g_protectAttempts.load()),
                static_cast<unsigned long long>(g_protectFailures.load()),
                static_cast<unsigned long long>(g_protectTimeouts.load()),
                static_cast<unsigned long long>(g_protectDropped.load()),
                g_protectLastFd.load());
  napi_value result = nullptr;
  napi_create_string_utf8(env, buffer, NAPI_AUTO_LENGTH, &result);
  return result;
}

// ---------------------------------------------------------------------------
// Module registration.
// ---------------------------------------------------------------------------
napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
      {"initCoreAsync", nullptr, InitCoreAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"quickStartAsync", nullptr, QuickStartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"invokeAction", nullptr, InvokeAction, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"startTun", nullptr, StartTun, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stopTun", nullptr, StopTun, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getRunTime", nullptr, GetRunTime, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getAndroidVpnOptions", nullptr, GetAndroidVpnOptions, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getCurrentProfileName", nullptr, GetCurrentProfileName, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setState", nullptr, SetState, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"shutdownCore", nullptr, ShutdownCore, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"notifyProtected", nullptr, NotifyProtected, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getProtectStats", nullptr, GetProtectStats, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setEventSink", nullptr, SetEventSink, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  if (napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]),
                             descriptors) != napi_ok) {
    napi_throw_error(env, "NAPI_EXPORT_ERROR", "Unable to initialize clash bridge.");
    return nullptr;
  }
  return exports;
}

napi_module clashBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "clash_bridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterClashBridgeModule() {
  napi_module_register(&clashBridgeModule);
}