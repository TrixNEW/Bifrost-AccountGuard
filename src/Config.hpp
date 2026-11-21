#pragma once

#include <algorithm>
#include <cctype>
#include <charconv>
#include <cstdint>
#include <expected>
#include <format>
#include <string>
#include <string_view>
#include <vector>

namespace accountguard {

constexpr std::int64_t secondsPerDay = 86400;
constexpr std::int64_t maxMinAgeDays = 36500;
constexpr std::size_t maxKickBytes = 512;
constexpr std::size_t maxXuidDigits = 20;

enum class MissingDate { deny, allow };

struct Config {
    std::int64_t minAgeSeconds = 30 * secondsPerDay;
    std::string kickMessage = "Your account is too new to play here. Please come back when it is {days} days old.";
    MissingDate missingDate = MissingDate::deny;
    // Sorted, so a lookup never allocates
    std::vector<std::uint64_t> exemptXuids;

    bool exempt(std::uint64_t xuid) const noexcept {
        return xuid != 0 && std::ranges::binary_search(exemptXuids, xuid);
    }

    std::string renderKick() const {
        std::string text = kickMessage;
        const auto at = text.find("{days}");
        if (at != std::string::npos) text.replace(at, 6, std::to_string(minAgeSeconds / secondsPerDay));
        return text;
    }
};

// An XUID is digits only and nonzero, the same rule Bifrost applies to its operators
constexpr bool parseXuid(std::string_view text, std::uint64_t &out) noexcept {
    if (text.empty() || text.size() > maxXuidDigits) return false;
    if (!std::ranges::all_of(text, [](char c) { return c >= '0' && c <= '9'; })) return false;
    std::uint64_t value = 0;
    const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
    if (error != std::errc{} || end != text.data() + text.size() || value == 0) return false;
    out = value;
    return true;
}

namespace detail {

using Result = std::expected<void, std::string>;

inline std::string_view trim(std::string_view text) noexcept {
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) text.remove_prefix(1);
    while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) text.remove_suffix(1);
    return text;
}

// Reads one "..." string with \" and \\ escapes and leaves what follows it in `rest`
inline std::expected<std::string, std::string> readString(std::string_view &rest) {
    std::string value;
    for (std::size_t i = 1; i < rest.size(); ++i) {
        const char c = rest[i];
        if (c == '"') {
            rest.remove_prefix(i + 1);
            return value;
        }
        if (c == '\\') {
            if (++i == rest.size() || (rest[i] != '"' && rest[i] != '\\')) return std::unexpected("only \\\" and \\\\ escapes are supported");
        }
        value.push_back(rest[i]);
    }
    return std::unexpected("string is not closed");
}

inline std::expected<std::vector<std::string>, std::string> readStrings(std::string_view value) {
    std::vector<std::string> items;
    value = trim(value);
    if (value.size() < 2 || value.front() != '[' || value.back() != ']') return std::unexpected("expected a list of strings on one line");
    value = trim(value.substr(1, value.size() - 2));
    while (!value.empty()) {
        if (value.front() != '"') return std::unexpected("list items must be strings");
        auto item = readString(value);
        if (!item) return std::unexpected(item.error());
        items.push_back(std::move(*item));
        value = trim(value);
        if (value.empty()) break;
        if (value.front() != ',') return std::unexpected("expected a comma between list items");
        value = trim(value.substr(1));
    }
    return items;
}

inline std::expected<std::string, std::string> readText(std::string_view value) {
    value = trim(value);
    if (value.empty() || value.front() != '"') return std::unexpected("expected a string");
    auto text = readString(value);
    if (!text) return text;
    if (!trim(value).empty() && trim(value).front() != '#') return std::unexpected("unexpected text after the string");
    return text;
}

inline std::expected<std::int64_t, std::string> readInteger(std::string_view value) {
    value = trim(value);
    if (const auto comment = value.find('#'); comment != std::string_view::npos) value = trim(value.substr(0, comment));
    std::int64_t number = 0;
    const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), number);
    if (value.empty() || error != std::errc{} || end != value.data() + value.size()) return std::unexpected("expected a whole number");
    return number;
}

inline std::string_view stripComment(std::string_view line) noexcept {
    bool quoted = false;
    for (std::size_t i = 0; i < line.size(); ++i) {
        if (line[i] == '\\' && quoted) ++i;
        else if (line[i] == '"') quoted = !quoted;
        else if (line[i] == '#' && !quoted) return line.substr(0, i);
    }
    return line;
}

}

// A flat `key = value` file, strict about unknown keys, duplicates and bad values so a typo never weakens the check
inline std::expected<Config, std::string> parseConfig(std::string_view source) {
    Config config;
    bool seen[4]{};
    std::size_t number = 0;
    const auto fail = [&](std::string_view why) { return std::unexpected(std::format("line {}: {}", number, why)); };
    while (!source.empty()) {
        const auto end = source.find('\n');
        auto line = detail::trim(detail::stripComment(source.substr(0, end)));
        source.remove_prefix(end == std::string_view::npos ? source.size() : end + 1);
        ++number;
        if (line.empty()) continue;
        const auto equals = line.find('=');
        if (equals == std::string_view::npos) return fail("expected key = value");
        const auto key = detail::trim(line.substr(0, equals));
        const auto value = detail::trim(line.substr(equals + 1));

        const std::string_view keys[] = {"min_age_days", "kick_message", "missing_date", "exempt_xuids"};
        const auto found = std::ranges::find(keys, key);
        if (found == std::end(keys)) return fail(std::format("unknown key \"{}\"", key));
        const auto index = static_cast<std::size_t>(found - std::begin(keys));
        if (seen[index]) return fail(std::format("\"{}\" is set twice", key));
        seen[index] = true;

        switch (index) {
        case 0: {
            const auto days = detail::readInteger(value);
            if (!days) return fail(days.error());
            if (*days < 0 || *days > maxMinAgeDays) return fail(std::format("min_age_days must be 0 to {}", maxMinAgeDays));
            config.minAgeSeconds = *days * secondsPerDay;
            break;
        }
        case 1: {
            auto text = detail::readText(value);
            if (!text) return fail(text.error());
            if (text->empty() || text->size() > maxKickBytes) return fail(std::format("kick_message must be 1 to {} bytes", maxKickBytes));
            config.kickMessage = std::move(*text);
            break;
        }
        case 2: {
            const auto text = detail::readText(value);
            if (!text) return fail(text.error());
            if (*text == "deny") config.missingDate = MissingDate::deny;
            else if (*text == "allow") config.missingDate = MissingDate::allow;
            else return fail("missing_date must be \"deny\" or \"allow\"");
            break;
        }
        default: {
            const auto items = detail::readStrings(value);
            if (!items) return fail(items.error());
            for (const auto &item : *items) {
                std::uint64_t xuid = 0;
                if (!parseXuid(item, xuid)) return fail(std::format("\"{}\" is not a XUID; list digits only, never names", item));
                config.exemptXuids.push_back(xuid);
            }
            std::ranges::sort(config.exemptXuids);
            config.exemptXuids.erase(std::ranges::unique(config.exemptXuids).begin(), config.exemptXuids.end());
            break;
        }
        }
    }
    return config;
}

}
