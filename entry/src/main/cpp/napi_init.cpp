#include "napi/native_api.h"

#include <cmath>
#include <cstdint>
#include <dlfcn.h>
#include <limits>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

namespace {
constexpr size_t MAX_REQUEST_BYTES = 1024 * 1024;
constexpr const char *QUIET_LOG_REQUEST = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":0}";

// Modern TDLib JSON C ABI: https://github.com/tdlib/td/blob/master/td/telegram/td_json_client.h
using CreateClientFn = int (*)();
using SendFn = void (*)(int, const char *);
using ReceiveFn = const char *(*)(double);
using ExecuteFn = const char *(*)(const char *);

struct TdlibApi {
    void *library = nullptr;
    CreateClientFn createClient = nullptr;
    SendFn send = nullptr;
    ReceiveFn receive = nullptr;
    ExecuteFn execute = nullptr;
    bool available = false;
};

TdlibApi api;
std::once_flag loadOnce;
// td_receive and td_execute invalidate the previous returned buffer. Protect both.
std::mutex receiveMutex;
std::mutex clientsMutex;
std::unordered_set<int> createdClients;

void LoadTdlib()
{
    std::call_once(loadOnce, []() {
        void *library = dlopen("libtdjson.so", RTLD_NOW | RTLD_LOCAL);
        if (library == nullptr) {
            return;
        }
        auto createClient = reinterpret_cast<CreateClientFn>(dlsym(library, "td_create_client_id"));
        auto send = reinterpret_cast<SendFn>(dlsym(library, "td_send"));
        auto receive = reinterpret_cast<ReceiveFn>(dlsym(library, "td_receive"));
        auto execute = reinterpret_cast<ExecuteFn>(dlsym(library, "td_execute"));
        if (createClient == nullptr || send == nullptr || receive == nullptr || execute == nullptr) {
            dlclose(library);
            return;
        }
        api.library = library;
        api.createClient = createClient;
        api.send = send;
        api.receive = receive;
        api.execute = execute;
        api.available = true;
        // Keep the library loaded for process lifetime: TDLib owns asynchronous threads.
        // No JSON request, authorization value, or received message is ever logged here.
    });
}

bool RequireTdlib(napi_env env)
{
    LoadTdlib();
    if (!api.available) {
        napi_throw_error(env, "TDLIB_NOT_LINKED", "TDLib is unavailable. Package a compatible libtdjson.so first.");
        return false;
    }
    return true;
}

bool GetArguments(napi_env env, napi_callback_info info, napi_value *args, size_t expected)
{
    // Callers provide one extra slot to distinguish excess arguments.
    size_t count = expected + 1;
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok) {
        napi_throw_error(env, "NAPI_ARGUMENT_ERROR", "Unable to read native arguments.");
        return false;
    }
    if (count != expected) {
        napi_throw_type_error(env, "INVALID_ARGUMENT_COUNT", "Unexpected number of arguments.");
        return false;
    }
    return true;
}

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    if (napi_create_string_utf8(env, value.data(), value.size(), &result) != napi_ok) {
        napi_throw_error(env, "NAPI_STRING_ERROR", "Unable to allocate native result.");
        return nullptr;
    }
    return result;
}

napi_value GetTdlibStatus(napi_env env, napi_callback_info info)
{
    napi_value args[1] = {nullptr};
    if (!GetArguments(env, info, args, 0)) {
        return nullptr;
    }
    LoadTdlib();
    return MakeString(env, api.available ? "available" : "not-linked");
}

napi_value CreateClient(napi_env env, napi_callback_info info)
{
    napi_value args[1] = {nullptr};
    if (!GetArguments(env, info, args, 0) || !RequireTdlib(env)) {
        return nullptr;
    }
    int clientId;
    {
        std::lock_guard<std::mutex> receiveLock(receiveMutex);
        // Silence TDLib before initialization, and explicitly keep it quiet after creation.
        api.execute(QUIET_LOG_REQUEST);
        clientId = api.createClient();
        api.execute(QUIET_LOG_REQUEST);
    }
    if (clientId <= 0) {
        napi_throw_error(env, "TDLIB_CLIENT_ERROR", "TDLib did not create a valid client.");
        return nullptr;
    }
    {
        std::lock_guard<std::mutex> clientsLock(clientsMutex);
        createdClients.insert(clientId);
    }
    napi_value result = nullptr;
    if (napi_create_int32(env, clientId, &result) != napi_ok) {
        api.send(clientId, "{\"@type\":\"close\"}");
        napi_throw_error(env, "NAPI_NUMBER_ERROR", "Unable to return TDLib client identifier.");
        return nullptr;
    }
    return result;
}

napi_value Send(napi_env env, napi_callback_info info)
{
    napi_value args[3] = {nullptr, nullptr, nullptr};
    if (!GetArguments(env, info, args, 2)) {
        return nullptr;
    }
    napi_valuetype idType = napi_undefined;
    napi_valuetype requestType = napi_undefined;
    double id = 0;
    if (napi_typeof(env, args[0], &idType) != napi_ok || idType != napi_number ||
        napi_get_value_double(env, args[0], &id) != napi_ok || !std::isfinite(id) ||
        std::floor(id) != id || id <= 0 || id > std::numeric_limits<int32_t>::max()) {
        napi_throw_type_error(env, "INVALID_CLIENT_ID", "clientId must be a positive 32-bit integer.");
        return nullptr;
    }
    if (napi_typeof(env, args[1], &requestType) != napi_ok || requestType != napi_string) {
        napi_throw_type_error(env, "INVALID_REQUEST", "request must be a JSON string.");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, "INVALID_REQUEST", "Unable to read request string.");
        return nullptr;
    }
    if (length == 0 || length > MAX_REQUEST_BYTES) {
        napi_throw_range_error(env, "INVALID_REQUEST_SIZE", "request must contain 1 to 1048576 UTF-8 bytes.");
        return nullptr;
    }
    std::vector<char> request(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, args[1], request.data(), request.size(), &copied) != napi_ok ||
        copied != length) {
        napi_throw_type_error(env, "INVALID_REQUEST", "Unable to copy request string.");
        return nullptr;
    }
    if (std::string(request.data(), length).find('\0') != std::string::npos) {
        napi_throw_type_error(env, "INVALID_REQUEST", "request must not contain embedded NUL bytes.");
        return nullptr;
    }
    if (!RequireTdlib(env)) {
        return nullptr;
    }
    const int clientId = static_cast<int>(id);
    {
        std::lock_guard<std::mutex> clientsLock(clientsMutex);
        if (createdClients.find(clientId) == createdClients.end()) {
            napi_throw_range_error(env, "UNKNOWN_CLIENT_ID", "clientId was not created by this bridge.");
            return nullptr;
        }
    }
    // TDLib validates the JSON schema and reports protocol errors through receive().
    api.send(clientId, request.data());
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Receive(napi_env env, napi_callback_info info)
{
    napi_value args[1] = {nullptr};
    if (!GetArguments(env, info, args, 0) || !RequireTdlib(env)) {
        return nullptr;
    }
    std::string update;
    {
        std::lock_guard<std::mutex> receiveLock(receiveMutex);
        const char *result = api.receive(0.0); // Poll only; never wait on the ArkUI thread.
        if (result != nullptr) {
            update.assign(result); // Copy before td_receive/td_execute can invalidate this pointer.
        }
    }
    return MakeString(env, update);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"getTdlibStatus", nullptr, GetTdlibStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createClient", nullptr, CreateClient, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"send", nullptr, Send, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"receive", nullptr, Receive, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    if (napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors) != napi_ok) {
        napi_throw_error(env, "NAPI_EXPORT_ERROR", "Unable to initialize TDLib bridge.");
        return nullptr;
    }
    return exports;
}

napi_module entryModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};
} // namespace

extern "C" __attribute__((constructor)) void RegisterEntryModule()
{
    napi_module_register(&entryModule);
}
