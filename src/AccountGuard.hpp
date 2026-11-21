#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <format>
#include <string>
#include <string_view>
#include <utility>

#include "AccountAge.hpp"
#include "Config.hpp"
#include "bifrost_plugin.h"

namespace accountguard {

inline bifrost_str toStr(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

class AccountGuard {
public:
    explicit AccountGuard(Config settings) : config(std::move(settings)), kick(config.renderKick()) {}

    // Needs the admission decision and `player_account`, so an older host can't silently skip the check
    static bool supported(const bifrost_host &host) noexcept {
        return BIFROST_HOST_HAS(&host, player_account) && BIFROST_HOST_HAS(&host, disconnect);
    }

    bifrost_status start(const bifrost_host &api) noexcept {
        host = &api;
        return host->subscribe(host->context, BIFROST_EVENT_PLAYER_AUTHENTICATED, onAuthenticated, this);
    }

    void stop() noexcept {
        log(BIFROST_LOG_INFO, "refused {} account(s) of {} checked", refused.load(), checked.load());
    }

    // The verdict for a player Bifrost has just verified, with the host calls kept apart from the rule itself
    Verdict check(bifrost_player player, std::int64_t now) noexcept {
        if (config.minAgeSeconds == 0) return Verdict::allowed;
        bifrost_player_info info{};
        bifrost_player_account account{};
        const auto infoStatus = host->player_info(host->context, player, &info, sizeof(info));
        const auto accountStatus = host->player_account(host->context, player, &account, sizeof(account));
        // Without either answer nothing is known, so even `missing_date = "allow"` doesn't admit
        if (infoStatus != BIFROST_STATUS_OK || accountStatus != BIFROST_STATUS_OK) return Verdict::missingDate;
        const auto created = verifiedCreation(accountStatus, account);
        const auto verdict = judge(config, verifiedXuid(info), created, now);
        if (!admits(verdict)) {
            const std::string_view name{reinterpret_cast<const char *>(info.name), info.name_len};
            const auto age = created ? std::format("{} day(s) old", std::max<std::int64_t>(0, now - *created) / secondsPerDay) : std::string{"of unknown age"};
            log(BIFROST_LOG_INFO, "refused {}: account {}", name, age);
        }
        return verdict;
    }

private:
    static AccountGuard &from(void *user) noexcept {
        return *static_cast<AccountGuard *>(user);
    }

    // Only an Xbox-verified XUID can exempt anyone, never a name or anything the client claims
    static std::uint64_t verifiedXuid(const bifrost_player_info &info) noexcept {
        if (info.state.authentication != BIFROST_AUTHENTICATION_AUTHENTICATED || info.online == 0) return 0;
        std::uint64_t xuid = 0;
        const auto len = std::min<std::size_t>(info.xuid_len, sizeof(info.xuid));
        return parseXuid({reinterpret_cast<const char *>(info.xuid), len}, xuid) ? xuid : 0;
    }

    static void onAuthenticated(void *user, const bifrost_event *event, bifrost_transfer_decision *decision) noexcept {
        auto &self = from(user);
        // Only the admission owner gets a decision, and without one nothing could be refused
        if (!decision) return;
        const auto now = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        self.checked.fetch_add(1, std::memory_order_relaxed);
        if (admits(self.check(event->player, now))) return;
        self.refused.fetch_add(1, std::memory_order_relaxed);
        // Holding the login keeps the backend out until the queued disconnect closes it with our own message.
        // Cancelling also refuses, but Bifrost then shows its own text, so it is only the fallback.
        const auto queued = self.host->disconnect(self.host->context, event->player, toStr(self.kick), nullptr, nullptr);
        decision->action = queued == BIFROST_STATUS_OK ? BIFROST_TRANSFER_HOLD_LOGIN : BIFROST_TRANSFER_CANCEL;
    }

    template <typename... Args>
    void log(bifrost_log_level level, std::format_string<Args...> pattern, Args &&...args) noexcept {
        char buffer[256];
        const auto result = std::format_to_n(buffer, sizeof(buffer), pattern, std::forward<Args>(args)...);
        host->log(host->context, level, toStr({buffer, static_cast<std::size_t>(result.out - buffer)}));
    }

    const bifrost_host *host{};
    const Config config;
    const std::string kick;
    std::atomic<std::uint64_t> checked{0};
    std::atomic<std::uint64_t> refused{0};
};

}
