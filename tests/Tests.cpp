#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>

#include "AccountGuard.hpp"

using namespace accountguard;

namespace {

int failures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
            ++failures; \
        } \
    } while (0)

constexpr std::int64_t day = secondsPerDay;
constexpr std::int64_t now = 1'700'000'000;
constexpr std::uint64_t vip = 2535400000000001;
constexpr std::uint64_t other = 2535400000000002;

Config withDays(std::int64_t days) {
    Config config;
    config.minAgeSeconds = days * day;
    return config;
}

void threshold() {
    const auto config = withDays(30);
    CHECK(judge(config, 0, now - 30 * day, now) == Verdict::allowed);
    CHECK(judge(config, 0, now - 30 * day + 1, now) == Verdict::tooNew);
    CHECK(judge(config, 0, now - 400 * day, now) == Verdict::allowed);
    CHECK(judge(config, 0, now, now) == Verdict::tooNew);
    CHECK(judge(withDays(7), 0, now - 8 * day, now) == Verdict::allowed);
    CHECK(judge(withDays(7), 0, now - 6 * day, now) == Verdict::tooNew);
    CHECK(Config{}.minAgeSeconds == 30 * day);
    CHECK(judge(withDays(0), 0, std::nullopt, now) == Verdict::allowed);
    CHECK(judge(withDays(0), 0, now, now) == Verdict::allowed);
}

void missingAndInvalidDates() {
    auto config = withDays(30);
    CHECK(config.missingDate == MissingDate::deny);
    CHECK(judge(config, 0, std::nullopt, now) == Verdict::missingDate);
    // A date that can't be real is as good as none, so it never reads as an old account
    CHECK(judge(config, 0, now + futureSlackSeconds + 1, now) == Verdict::missingDate);
    CHECK(judge(config, 0, now + futureSlackSeconds, now) == Verdict::tooNew);
    CHECK(judge(config, 0, now + 1, now) == Verdict::tooNew);
    config.missingDate = MissingDate::allow;
    CHECK(judge(config, 0, std::nullopt, now) == Verdict::allowed);
    CHECK(judge(config, 0, now + futureSlackSeconds + 1, now) == Verdict::allowed);
    // Allowing a missing date never excuses a date that is present and too recent
    CHECK(judge(config, 0, now - day, now) == Verdict::tooNew);

    bifrost_player_account account{};
    account.struct_size = sizeof(account);
    account.available = BIFROST_ACCOUNT_PLAYFAB_CREATED;
    account.playfab_created_s = now - 40 * day;
    CHECK(verifiedCreation(BIFROST_STATUS_OK, account) == now - 40 * day);
    CHECK(!verifiedCreation(BIFROST_STATUS_STALE_HANDLE, account));
    CHECK(!verifiedCreation(BIFROST_STATUS_FAILED, account));
    auto unavailable = account;
    unavailable.available = 0;
    CHECK(!verifiedCreation(BIFROST_STATUS_OK, unavailable));
    auto header = account;
    header.struct_size = 8;
    CHECK(!verifiedCreation(BIFROST_STATUS_OK, header));
    auto zero = account;
    zero.playfab_created_s = 0;
    CHECK(!verifiedCreation(BIFROST_STATUS_OK, zero));
    auto negative = account;
    negative.playfab_created_s = -1;
    CHECK(!verifiedCreation(BIFROST_STATUS_OK, negative));
}

void exemptions() {
    auto config = withDays(30);
    config.exemptXuids = {vip};
    CHECK(judge(config, vip, now - day, now) == Verdict::exempt);
    CHECK(judge(config, vip, std::nullopt, now) == Verdict::exempt);
    CHECK(judge(config, other, now - day, now) == Verdict::tooNew);
    // Zero stands for an XUID Xbox didn't verify, which can never match
    config.exemptXuids = {0, vip};
    CHECK(judge(config, 0, now - day, now) == Verdict::tooNew);
    CHECK(!Config{}.exempt(vip));
}

void configFile() {
    const auto defaults = parseConfig("");
    CHECK(defaults && defaults->minAgeSeconds == 30 * day && defaults->missingDate == MissingDate::deny && defaults->exemptXuids.empty());

    const auto full = parseConfig(
        "# comment\n"
        "min_age_days = 14 # trailing\n"
        "kick_message = \"Wait {days} days, \\\"friend\\\" # not a comment\"\n"
        "missing_date = \"allow\"\n"
        "exempt_xuids = [ \"2535400000000002\", \"2535400000000001\", \"2535400000000001\" ]\n");
    CHECK(full && full->minAgeSeconds == 14 * day && full->missingDate == MissingDate::allow);
    CHECK(full && full->renderKick() == "Wait 14 days, \"friend\" # not a comment");
    CHECK(full && full->exemptXuids == std::vector<std::uint64_t>({vip, other}));
    CHECK(full && full->exempt(vip) && full->exempt(other) && !full->exempt(3));

    for (const char *bad : {
             "min_age = 3\n",
             "min_age_days = 30\nmin_age_days = 30\n",
             "min_age_days = -1\n",
             "min_age_days = 36501\n",
             "min_age_days = \"30\"\n",
             "min_age_days = 3.5\n",
             "min_age_days\n",
             "kick_message = \"\"\n",
             "kick_message = Welcome\n",
             "kick_message = \"open\n",
             "kick_message = \"a\" extra\n",
             "kick_message = \"bad \\n escape\"\n",
             "missing_date = \"maybe\"\n",
             "missing_date = allow\n",
             "exempt_xuids = \"2535400000000001\"\n",
             "exempt_xuids = [2535400000000001]\n",
             "exempt_xuids = [\"Steve\"]\n",
             "exempt_xuids = [\"0\"]\n",
             "exempt_xuids = [\"-5\"]\n",
             "exempt_xuids = [\"123456789012345678901\"]\n",
             "exempt_xuids = [\"1\" \"2\"]\n",
             "exempt_xuids = [\"1\",\n",
         }) {
        CHECK(!parseConfig(bad));
    }
    CHECK(!parseConfig(std::string("kick_message = \"") + std::string(maxKickBytes + 1, 'x') + "\"\n"));
    CHECK(parseConfig(std::string("kick_message = \"") + std::string(maxKickBytes, 'x') + "\"\n"));

    // The shipped example has to stay loadable and mean what the docs say
    std::ifstream file{ACCOUNTGUARD_EXAMPLE_CONFIG, std::ios::binary};
    CHECK(file.good());
    const std::string text{std::istreambuf_iterator<char>{file}, {}};
    const auto example = parseConfig(text);
    CHECK(example && example->minAgeSeconds == 30 * day && example->missingDate == MissingDate::deny && example->exemptXuids.empty());
    CHECK(example && example->renderKick().find("30 days") != std::string::npos);
}

// A stand-in for Bifrost that records what the plugin asks of it
struct FakeHost {
    bifrost_player_info info{};
    bifrost_player_account account{};
    bifrost_status infoStatus = BIFROST_STATUS_OK;
    bifrost_status accountStatus = BIFROST_STATUS_OK;
    bifrost_status disconnectStatus = BIFROST_STATUS_OK;
    int disconnects = 0;
    std::string reason;
    bifrost_event_fn callback = nullptr;
    void *user = nullptr;
    bifrost_host table{};

    static FakeHost &of(void *context) {
        return *static_cast<FakeHost *>(context);
    }

    FakeHost() {
        table.struct_size = sizeof(table);
        table.abi_version = BIFROST_ABI_VERSION;
        table.context = this;
        table.log = [](void *, bifrost_log_level, bifrost_str) noexcept {};
        table.subscribe = [](void *context, bifrost_event_kind kind, bifrost_event_fn fn, void *user) noexcept -> bifrost_status {
            auto &self = of(context);
            if (kind != BIFROST_EVENT_PLAYER_AUTHENTICATED) return BIFROST_STATUS_INVALID_ARGUMENT;
            self.callback = fn;
            self.user = user;
            return BIFROST_STATUS_OK;
        };
        table.player_info = [](void *context, bifrost_player, bifrost_player_info *out, size_t) noexcept {
            auto &self = of(context);
            *out = self.info;
            return self.infoStatus;
        };
        table.player_account = [](void *context, bifrost_player, bifrost_player_account *out, size_t) noexcept {
            auto &self = of(context);
            *out = self.account;
            return self.accountStatus;
        };
        table.disconnect = [](void *context, bifrost_player, bifrost_str reason, bifrost_task_done_fn, void *) noexcept {
            auto &self = of(context);
            ++self.disconnects;
            self.reason.assign(reinterpret_cast<const char *>(reason.ptr), reason.len);
            return self.disconnectStatus;
        };
        verified(std::to_string(vip), true);
        created(std::time(nullptr) - 90 * day);
    }

    void verified(const std::string &xuid, bool online, bifrost_authentication_state state = BIFROST_AUTHENTICATION_AUTHENTICATED) {
        info = {};
        info.struct_size = sizeof(info);
        info.state.authentication = state;
        info.online = online;
        info.xuid_len = static_cast<std::uint32_t>(xuid.size());
        std::memcpy(info.xuid, xuid.data(), xuid.size());
        info.name_len = 5;
        std::memcpy(info.name, "Steve", 5);
    }

    void created(std::int64_t seconds) {
        account = {};
        account.struct_size = sizeof(account);
        account.available = BIFROST_ACCOUNT_PLAYFAB_CREATED;
        account.playfab_created_s = seconds;
    }

    // What Bifrost does when a login is verified, ending with the decision it acts on
    bifrost_transfer_action login(bool admissionOwner = true) {
        bifrost_event event{};
        event.struct_size = sizeof(event);
        event.kind = BIFROST_EVENT_PLAYER_AUTHENTICATED;
        event.player.id = 1;
        bifrost_transfer_decision decision{};
        decision.struct_size = sizeof(decision);
        callback(user, &event, admissionOwner ? &decision : nullptr);
        return decision.action;
    }
};

void rejection(Config config, const auto &arrange, bifrost_transfer_action expected, int disconnects) {
    FakeHost host;
    arrange(host);
    AccountGuard guard{std::move(config)};
    CHECK(guard.start(host.table) == BIFROST_STATUS_OK);
    CHECK(host.login() == expected);
    CHECK(host.disconnects == disconnects);
}

void admission() {
    const auto nothing = [](FakeHost &) {};
    const auto recent = [](FakeHost &host) { host.created(std::time(nullptr) - 2 * day); };

    // An old enough account goes straight on to a backend
    rejection(Config{}, nothing, BIFROST_TRANSFER_PROCEED, 0);

    // A new one is held off the backend and told why in the configured words
    {
        FakeHost host;
        recent(host);
        host.verified("2535400000000009", true);
        auto config = Config{};
        config.kickMessage = "Come back in {days} days";
        AccountGuard guard{config};
        CHECK(guard.start(host.table) == BIFROST_STATUS_OK);
        CHECK(host.login() == BIFROST_TRANSFER_HOLD_LOGIN);
        CHECK(host.disconnects == 1 && host.reason == "Come back in 30 days");
    }

    // If the disconnect can't be queued the login is still refused, just with Bifrost's own text
    rejection(Config{}, [&](FakeHost &host) { recent(host); host.disconnectStatus = BIFROST_STATUS_BUSY; }, BIFROST_TRANSFER_CANCEL, 1);

    // No date at all follows missing_date, which refuses by default
    rejection(Config{}, [](FakeHost &host) { host.account = {}; host.account.struct_size = sizeof(host.account); }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
    {
        Config config;
        config.missingDate = MissingDate::allow;
        rejection(config, [](FakeHost &host) { host.account = {}; host.account.struct_size = sizeof(host.account); }, BIFROST_TRANSFER_PROCEED, 0);
        rejection(config, [](FakeHost &host) { host.created(std::time(nullptr) + 10 * day); }, BIFROST_TRANSFER_PROCEED, 0);
    }
    rejection(Config{}, [](FakeHost &host) { host.created(std::time(nullptr) + 10 * day); }, BIFROST_TRANSFER_HOLD_LOGIN, 1);

    // Failing to learn anything about the player refuses, even where a missing date would be allowed
    {
        Config config;
        config.missingDate = MissingDate::allow;
        rejection(config, [](FakeHost &host) { host.infoStatus = BIFROST_STATUS_STALE_HANDLE; }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
        rejection(config, [](FakeHost &host) { host.accountStatus = BIFROST_STATUS_FAILED; }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
    }

    // Exempt XUIDs skip the check, but only when Xbox verified them
    {
        Config config;
        config.exemptXuids = {vip};
        const auto freshVip = [](FakeHost &host) { host.created(std::time(nullptr) - day); };
        rejection(config, freshVip, BIFROST_TRANSFER_PROCEED, 0);
        rejection(config, [&](FakeHost &host) { freshVip(host); host.verified(std::to_string(vip), false); }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
        rejection(config, [&](FakeHost &host) { freshVip(host); host.verified(std::to_string(vip), true, BIFROST_AUTHENTICATION_PENDING); }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
        rejection(config, [&](FakeHost &host) { freshVip(host); host.verified("", true); }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
        rejection(config, [&](FakeHost &host) { freshVip(host); host.verified("Steve", true); }, BIFROST_TRANSFER_HOLD_LOGIN, 1);
    }

    // Turned off, nothing is asked of the host and nobody is refused
    {
        Config config;
        config.minAgeSeconds = 0;
        rejection(config, [](FakeHost &host) { host.infoStatus = BIFROST_STATUS_FAILED; }, BIFROST_TRANSFER_PROCEED, 0);
    }

    // Without a decision pointer the plugin doesn't own admission, so there is nothing it could refuse
    {
        FakeHost host;
        host.created(std::time(nullptr) - day);
        AccountGuard guard{Config{}};
        CHECK(guard.start(host.table) == BIFROST_STATUS_OK);
        CHECK(host.login(false) == BIFROST_TRANSFER_PROCEED);
        CHECK(host.disconnects == 0);
    }

    // A host that predates player_account is refused up front instead of silently skipping the check
    {
        FakeHost host;
        host.table.struct_size = offsetof(bifrost_host, player_account);
        CHECK(!AccountGuard::supported(host.table));
        host.table.struct_size = sizeof(host.table);
        CHECK(AccountGuard::supported(host.table));
    }
}

}

int main() {
    threshold();
    missingAndInvalidDates();
    exemptions();
    configFile();
    admission();
    if (failures == 0) std::puts("all AccountGuard tests passed");
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
