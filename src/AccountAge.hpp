#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

#include "Config.hpp"
#include "bifrost_plugin.h"

namespace accountguard {

// Microsoft's clocks and ours can disagree a little, so a date this far ahead is still a brand new account
constexpr std::int64_t futureSlackSeconds = 300;

enum class Verdict { allowed, exempt, tooNew, missingDate };

constexpr bool admits(Verdict verdict) noexcept {
    return verdict == Verdict::allowed || verdict == Verdict::exempt;
}

// The PlayFab creation time of a verified login, or nothing when Bifrost doesn't know it or the value can't be real
inline std::optional<std::int64_t> verifiedCreation(bifrost_status status, const bifrost_player_account &account) noexcept {
    constexpr auto needed = offsetof(bifrost_player_account, playfab_created_s) + sizeof(account.playfab_created_s);
    if (status != BIFROST_STATUS_OK || account.struct_size < needed) return std::nullopt;
    if ((account.available & BIFROST_ACCOUNT_PLAYFAB_CREATED) == 0 || account.playfab_created_s <= 0) return std::nullopt;
    return account.playfab_created_s;
}

// `xuid` is zero unless Xbox verified it. A date too far in the future counts as missing, never as old.
constexpr Verdict judge(const Config &config, std::uint64_t xuid, std::optional<std::int64_t> created, std::int64_t now) noexcept {
    if (config.minAgeSeconds == 0) return Verdict::allowed;
    if (config.exempt(xuid)) return Verdict::exempt;
    if (!created || *created > now + futureSlackSeconds) {
        return config.missingDate == MissingDate::allow ? Verdict::allowed : Verdict::missingDate;
    }
    return now - *created >= config.minAgeSeconds ? Verdict::allowed : Verdict::tooNew;
}

}
