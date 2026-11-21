#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <optional>
#include <string>

#include "AccountGuard.hpp"
#include "bifrost_manifest.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {

using accountguard::AccountGuard;

constexpr auto configName = "AccountGuard.toml";

// The settings sit beside the library, so a moved `plugins` directory takes them along
std::filesystem::path libraryDirectory() {
#ifdef _WIN32
    HMODULE module{};
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&libraryDirectory), &module)) return {};
    std::wstring path(MAX_PATH, L'\0');
    for (;;) {
        const auto length = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
        if (length == 0) return {};
        if (length < path.size()) {
            path.resize(length);
            return std::filesystem::path{path}.parent_path();
        }
        path.resize(path.size() * 2);
    }
#else
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void *>(&libraryDirectory), &info) || !info.dli_fname) return {};
    return std::filesystem::path{info.dli_fname}.parent_path();
#endif
}

void say(const bifrost_host &host, bifrost_log_level level, const std::string &text) noexcept {
    host.log(host.context, level, accountguard::toStr(text));
}

// A missing file means the defaults; a file that exists but doesn't parse stops the load, never weakens the check
std::optional<accountguard::Config> loadConfig(const bifrost_host &host) noexcept {
    try {
        const auto path = libraryDirectory() / configName;
        std::ifstream file{path, std::ios::binary};
        if (!file) {
            say(host, BIFROST_LOG_INFO, std::string{"no "} + configName + " beside the plugin, using the defaults");
            return accountguard::Config{};
        }
        const std::string text{std::istreambuf_iterator<char>{file}, {}};
        auto parsed = accountguard::parseConfig(text);
        if (!parsed) {
            say(host, BIFROST_LOG_ERR, path.string() + ": " + parsed.error());
            return std::nullopt;
        }
        return std::move(*parsed);
    } catch (...) {
        say(host, BIFROST_LOG_ERR, "can't read the settings");
        return std::nullopt;
    }
}

void onShutdown(void *state) noexcept {
    auto *self = static_cast<AccountGuard *>(state);
    self->stop();
    delete self;
}

}

extern "C" BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION || !AccountGuard::supported(*host)) return BIFROST_STATUS_INCOMPATIBLE;
    auto config = loadConfig(*host);
    if (!config) return BIFROST_STATUS_FAILED;
    std::unique_ptr<AccountGuard> guard;
    try {
        guard = std::make_unique<AccountGuard>(std::move(*config));
    } catch (...) {
        return BIFROST_STATUS_FAILED;
    }
    if (const auto status = guard->start(*host); status != BIFROST_STATUS_OK) return status;
    plugin->capabilities = BIFROST_CAPABILITY_EVENTS | BIFROST_CAPABILITY_ADMISSION;
    plugin->state = guard.release();
    plugin->shutdown = onShutdown;
    return BIFROST_STATUS_OK;
}
