#include <napi/native_api.h>
#include <unistd.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>
#include <string>
#include <memory>
#include <new>

#include "wireguard_go.h"

namespace {
constexpr size_t MaxConfigSize = 1024 * 1024;
constexpr size_t MaxRoutingSize = 4 * 1024 * 1024;
constexpr size_t MaxDNSConfigSize = 16 * 1024;

napi_value Fail(napi_env env, const char* message)
{
    napi_throw_error(env, nullptr, message);
    return nullptr;
}

napi_value InvalidArguments(napi_env env)
{
    napi_throw_type_error(env, nullptr, "Invalid WireGuard native arguments");
    return nullptr;
}

bool ReadInt(napi_env env, napi_value value, int min, int max, int& result)
{
    double number;
    if (napi_get_value_double(env, value, &number) != napi_ok ||
        !std::isfinite(number) || number != std::trunc(number) || number < min || number > max) {
        return false;
    }
    result = static_cast<int>(number);
    return true;
}

napi_value Undefined(napi_env env)
{
    napi_value value;
    return napi_get_undefined(env, &value) == napi_ok ? value : nullptr;
}

napi_value OpenSocket(napi_env env, napi_callback_info info)
{
    napi_value arg;
    size_t argc = 1;
    int port;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok ||
        argc != 1 || !ReadInt(env, arg, 0, 65535, port)) {
        return InvalidArguments(env);
    }
    const int fd = wg_open_socket(port);
    if (fd < 0) {
        return Fail(env, "Could not bind the WireGuard UDP socket");
    }
    napi_value result;
    if (napi_create_int32(env, fd, &result) != napi_ok) {
        close(fd);
        return Fail(env, "Could not return the WireGuard UDP descriptor");
    }
    return result;
}

napi_value CloseDescriptor(napi_env env, napi_callback_info info)
{
    napi_value arg;
    size_t argc = 1;
    int fd;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok ||
        argc != 1 || !ReadInt(env, arg, 0, INT32_MAX, fd)) {
        return InvalidArguments(env);
    }
    close(fd);
    return Undefined(env);
}

napi_value Start(napi_env env, napi_callback_info info)
{
    napi_value args[4];
    size_t argc = 4;
    int tunFd, udpFd, mtu;
    size_t length;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 4 ||
        !ReadInt(env, args[0], 0, INT32_MAX, tunFd) ||
        !ReadInt(env, args[1], 0, INT32_MAX, udpFd) || tunFd == udpFd ||
        napi_get_value_string_utf8(env, args[2], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > MaxConfigSize ||
        !ReadInt(env, args[3], 576, 9000, mtu)) {
        return InvalidArguments(env);
    }
    std::vector<char> config(length + 1);
    if (napi_get_value_string_utf8(env, args[2], config.data(), config.size(), &length) != napi_ok) {
        return InvalidArguments(env);
    }
    const int handle = wg_start(tunFd, udpFd, mtu, config.data(), length);
    switch (handle) {
        case -2:
            return Fail(env, "Could not use the protected WireGuard UDP socket");
        case -3:
            return Fail(env, "Could not use the system VPN tunnel descriptor");
        case -4:
            return Fail(env, "The WireGuard engine rejected the tunnel configuration");
        case -5:
            return Fail(env, "Could not activate the WireGuard engine");
        case -1:
            return InvalidArguments(env);
    }
    napi_value result;
    if (napi_create_int32(env, handle, &result) != napi_ok) {
        wg_stop(handle);
        return Fail(env, "Could not return the WireGuard tunnel handle");
    }
    return result;
}

napi_value StartConfigurations(napi_env env, napi_callback_info info, bool routed)
{
    napi_value args[5];
    const size_t expectedArgc = routed ? 5 : 4;
    size_t argc = expectedArgc;
    int tunFd, mtu;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != expectedArgc ||
        !ReadInt(env, args[0], 0, INT32_MAX, tunFd) ||
        !ReadInt(env, args[3], routed ? 1280 : 576, 9000, mtu)) {
        return InvalidArguments(env);
    }

    uint32_t udpCount = 0;
    uint32_t confCount = 0;
    bool isArray = false;
    if (napi_is_array(env, args[1], &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, args[1], &udpCount) != napi_ok ||
        napi_is_array(env, args[2], &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, args[2], &confCount) != napi_ok ||
        (!routed && udpCount == 0) || udpCount > 16 || udpCount != confCount) {
        return InvalidArguments(env);
    }

    std::vector<int> udpFds(udpCount);
    for (uint32_t index = 0; index < udpCount; ++index) {
        napi_value entry;
        int fd;
        if (napi_get_element(env, args[1], index, &entry) != napi_ok ||
            !ReadInt(env, entry, 0, INT32_MAX, fd) || fd == tunFd) {
            return InvalidArguments(env);
        }
        udpFds[index] = fd;
    }

    std::vector<std::string> configs(confCount);
    size_t total = 0;
    for (uint32_t index = 0; index < confCount; ++index) {
        napi_value entry;
        size_t length = 0;
        if (napi_get_element(env, args[2], index, &entry) != napi_ok ||
            napi_get_value_string_utf8(env, entry, nullptr, 0, &length) != napi_ok ||
            length == 0 || length > MaxConfigSize) {
            return InvalidArguments(env);
        }
        total += length;
        if (total > MaxConfigSize * 16) {
            return InvalidArguments(env);
        }
        configs[index].resize(length + 1);
        if (napi_get_value_string_utf8(env, entry, configs[index].data(), length + 1, &length) != napi_ok) {
            return InvalidArguments(env);
        }
    }

    std::vector<const char*> confPointers(confCount);
    for (uint32_t index = 0; index < confCount; ++index) {
        confPointers[index] = configs[index].c_str();
    }

    std::vector<char> routing;
    if (routed) {
        size_t length = 0;
        if (napi_get_value_string_utf8(env, args[4], nullptr, 0, &length) != napi_ok ||
            length == 0 || length > MaxRoutingSize) {
            return InvalidArguments(env);
        }
        routing.resize(length + 1);
        size_t copied = 0;
        if (napi_get_value_string_utf8(env, args[4], routing.data(), routing.size(), &copied) != napi_ok ||
            copied != length) {
            return InvalidArguments(env);
        }
        for (size_t index = 0; index < length; ++index) {
            if (routing[index] == '\0') {
                return InvalidArguments(env);
            }
        }
    }

    const int handle = routed
        ? wg_start_routed(tunFd, mtu, udpFds.data(), const_cast<char**>(confPointers.data()),
            static_cast<int>(confCount), routing.data())
        : wg_start_many(tunFd, mtu, udpFds.data(), const_cast<char**>(confPointers.data()),
            static_cast<int>(confCount));
    switch (handle) {
        case -7:
            return Fail(env, "The WireGuard engine rejected the domain routing configuration");
        case -6:
            return Fail(env, "Could not create the WireGuard domain routing gateway");
        case -2:
            return Fail(env, "Could not use the protected WireGuard UDP socket");
        case -3:
            return Fail(env, routed ? "Could not create the WireGuard VPN data path" :
                "Could not use the system VPN tunnel descriptor");
        case -4:
            return Fail(env, "The WireGuard engine rejected the tunnel configuration");
        case -5:
            return Fail(env, "Could not activate the WireGuard engine");
        case -1:
            return InvalidArguments(env);
    }
    napi_value result;
    if (napi_create_int32(env, handle, &result) != napi_ok) {
        wg_stop(handle);
        return Fail(env, "Could not return the WireGuard tunnel handle");
    }
    return result;
}

napi_value StartMany(napi_env env, napi_callback_info info)
{
    return StartConfigurations(env, info, false);
}

napi_value StartRouted(napi_env env, napi_callback_info info)
{
    return StartConfigurations(env, info, true);
}

napi_value UpdateRoutedDNS(napi_env env, napi_callback_info info)
{
    napi_value args[2];
    size_t argc = 2;
    int handle;
    size_t length = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 2 || !ReadInt(env, args[0], 1, INT32_MAX, handle) ||
        napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > MaxDNSConfigSize) {
        return InvalidArguments(env);
    }
    std::vector<char> dns(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, args[1], dns.data(), dns.size(), &copied) != napi_ok ||
        copied != length) {
        return InvalidArguments(env);
    }
    for (size_t index = 0; index < length; ++index) {
        if (dns[index] == '\0') {
            return InvalidArguments(env);
        }
    }
    if (wg_set_route_dns(handle, dns.data()) != 0) {
        return Fail(env, "Could not update the WireGuard underlying DNS servers");
    }
    return Undefined(env);
}

napi_value UpdateRoutedNetwork(napi_env env, napi_callback_info info)
{
    napi_value args[2];
    size_t argc = 2;
    int handle;
    size_t length = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 2 || !ReadInt(env, args[0], 1, INT32_MAX, handle) ||
        napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > 64 * 1024) {
        return InvalidArguments(env);
    }
    std::vector<char> dns(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, args[1], dns.data(), dns.size(), &copied) != napi_ok ||
        copied != length) {
        return InvalidArguments(env);
    }
    for (size_t index = 0; index < length; ++index) {
        if (dns[index] == '\0') {
            return InvalidArguments(env);
        }
    }
    if (wg_set_route_network(handle, dns.data()) != 0) {
        return Fail(env, "Could not update the underlying network routes and DNS");
    }
    return Undefined(env);
}

napi_value Stop(napi_env env, napi_callback_info info)
{
    napi_value arg;
    size_t argc = 1;
    int handle;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok ||
        argc != 1 || !ReadInt(env, arg, 1, INT32_MAX, handle)) {
        return InvalidArguments(env);
    }
    wg_stop(handle);
    return Undefined(env);
}

napi_value RebindTransport(napi_env env, napi_callback_info info)
{
    napi_value args[3]; size_t argc = 3; int handle;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 3 ||
        !ReadInt(env, args[0], 1, INT32_MAX, handle)) { return InvalidArguments(env); }
    bool isArray = false; uint32_t count = 0, updatesCount = 0;
    if (napi_is_array(env, args[1], &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, args[1], &count) != napi_ok || count > 16 ||
        napi_is_array(env, args[2], &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, args[2], &updatesCount) != napi_ok || updatesCount != count) {
        return InvalidArguments(env);
    }
    std::vector<int> fds(count);
    std::vector<std::string> updates(count);
    std::vector<const char*> pointers(count);
    for (uint32_t index = 0; index < count; ++index) {
        napi_value value; size_t length = 0;
        if (napi_get_element(env, args[1], index, &value) != napi_ok ||
            !ReadInt(env, value, 0, INT32_MAX, fds[index]) ||
            napi_get_element(env, args[2], index, &value) != napi_ok ||
            napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > 128 * 1024) {
            return InvalidArguments(env);
        }
        updates[index].resize(length + 1);
        size_t copied = 0;
        if (napi_get_value_string_utf8(env, value, updates[index].data(), length + 1, &copied) != napi_ok || copied != length) {
            return InvalidArguments(env);
        }
        for (size_t offset = 0; offset < length; ++offset) {
            if (updates[index][offset] == '\0') { return InvalidArguments(env); }
        }
        pointers[index] = updates[index].c_str();
    }
    // The caller always owns its original descriptors. Go duplicates them and
    // owns only the copies, including cleanup when validation or rebinding fails.
    if (wg_rebind_transport(handle, fds.data(), const_cast<char**>(pointers.data()), static_cast<int>(count)) != 0) {
        return Fail(env, "Could not replace WireGuard network transports");
    }
    return Undefined(env);
}

bool SetNumber(napi_env env, napi_value object, const char* key, double number)
{
    napi_value value;
    return napi_create_double(env, number, &value) == napi_ok &&
        napi_set_named_property(env, object, key, value) == napi_ok;
}

napi_value Status(napi_env env, napi_callback_info info)
{
    napi_value arg;
    size_t argc = 1;
    int handle;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok ||
        argc != 1 || !ReadInt(env, arg, 1, INT32_MAX, handle)) {
        return InvalidArguments(env);
    }
    double sent = 0, received = 0, handshake = 0;
    const bool running = wg_status(handle, &sent, &received, &handshake) == 1;
    double selectedDNS = 0, selectedFlows = 0, directFlows = 0;
    wg_route_counts(handle, &selectedDNS, &selectedFlows, &directFlows);
    napi_value result, runningValue;
    if (napi_create_object(env, &result) != napi_ok ||
        !SetNumber(env, result, "sentBytes", sent) ||
        !SetNumber(env, result, "receivedBytes", received) ||
        !SetNumber(env, result, "lastHandshake", handshake) ||
        !SetNumber(env, result, "selectedDNS", selectedDNS) ||
        !SetNumber(env, result, "selectedFlows", selectedFlows) ||
        !SetNumber(env, result, "directFlows", directFlows) ||
        napi_get_boolean(env, running, &runningValue) != napi_ok ||
        napi_set_named_property(env, result, "running", runningValue) != napi_ok) {
        return Fail(env, "Could not return WireGuard tunnel status");
    }
    return result;
}

napi_value DetailStatus(napi_env env, napi_callback_info info)
{
    napi_value arg; size_t argc = 1; int handle;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1 ||
        !ReadInt(env, arg, 1, INT32_MAX, handle)) { return InvalidArguments(env); }
    char* raw = wg_detail_status(handle);
    napi_value result;
    napi_status status = napi_create_string_utf8(env, raw, NAPI_AUTO_LENGTH, &result);
    wg_free_string(raw);
    if (status != napi_ok) { return Fail(env, "Could not return connection details"); }
    return result;
}

napi_value ResourceUsage(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    if (napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr) != napi_ok) {
        return InvalidArguments(env);
    }
    char* raw = wg_resource_usage();
    napi_value result;
    const napi_status status = napi_create_string_utf8(env, raw, NAPI_AUTO_LENGTH, &result);
    wg_free_string(raw);
    if (status != napi_ok) { return Fail(env, "Could not return resource counters"); }
    return result;
}

struct RouteCheckWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int handle = 0;
    std::string request;
    char* result = nullptr;
    ~RouteCheckWork() { if (result != nullptr) { wg_free_string(result); } }
};

void ExecuteRouteCheck(napi_env, void* data)
{
    auto* work = static_cast<RouteCheckWork*>(data);
    // All DNS work runs off the ArkTS/UI thread. Go limits the lookup to five
    // seconds and only uses the active connection's configured DNS servers.
    work->result = wg_check_route(work->handle, work->request.data());
}

void CompleteRouteCheck(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<RouteCheckWork> work(static_cast<RouteCheckWork*>(data));
    napi_value value;
    if (status == napi_ok && work->result != nullptr &&
        napi_create_string_utf8(env, work->result, NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message;
        if (napi_create_string_utf8(env, "Route check could not complete", NAPI_AUTO_LENGTH, &message) == napi_ok &&
            napi_create_error(env, nullptr, message, &value) == napi_ok) {
            napi_reject_deferred(env, work->deferred, value);
        }
    }
    napi_delete_async_work(env, work->work);
}

napi_value CheckRoute(napi_env env, napi_callback_info info)
{
    napi_value args[2]; size_t argc = 2; int handle; size_t length = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2 ||
        !ReadInt(env, args[0], 1, INT32_MAX, handle) ||
        napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) != napi_ok || length == 0 || length > 8192) {
        return InvalidArguments(env);
    }
    std::unique_ptr<RouteCheckWork> work(new (std::nothrow) RouteCheckWork());
    if (!work) { return Fail(env, "Could not prepare route check"); }
    work->handle = handle;
    work->request.resize(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, args[1], work->request.data(), length + 1, &copied) != napi_ok || copied != length) {
        return InvalidArguments(env);
    }
    for (size_t i = 0; i < length; ++i) { if (work->request[i] == '\0') { return InvalidArguments(env); } }
    napi_value promise, name;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "WireGuardRouteCheck", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, nullptr, name, ExecuteRouteCheck, CompleteRouteCheck, work.get(), &work->work) != napi_ok) {
        return Fail(env, "Could not prepare asynchronous route check");
    }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        return Fail(env, "Could not queue route check");
    }
    work.release();
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor properties[] = {
        {"openSocket", nullptr, OpenSocket, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeSocket", nullptr, CloseDescriptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startMany", nullptr, StartMany, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startRouted", nullptr, StartRouted, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateRoutedDNS", nullptr, UpdateRoutedDNS, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateRoutedNetwork", nullptr, UpdateRoutedNetwork, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rebindTransport", nullptr, RebindTransport, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"detailStatus", nullptr, DetailStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resourceUsage", nullptr, ResourceUsage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"checkRoute", nullptr, CheckRoute, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        return Fail(env, "Could not initialize the WireGuard native module");
    }
    return exports;
}

napi_module module = {1, 0, nullptr, Init, "wireguard", nullptr, {0}};
} // namespace

extern "C" __attribute__((constructor)) void RegisterWireGuardModule()
{
    napi_module_register(&module);
}
