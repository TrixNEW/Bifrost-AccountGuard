# AccountGuard

A [Bifrost](https://github.com/TrixNEW/Bifrost) plugin that turns away accounts that are too new. It reads the PlayFab creation date
from the player's Microsoft-verified login, and refuses the login before the backend receives it.

## What "account age" means here

The date is the token's `pfcd` claim: when the account first signed in to Minecraft's PlayFab title. That is roughly the
first time the Microsoft account played Minecraft. It is **not** the age of the Xbox or Microsoft account itself, so an
old Microsoft account that never played Minecraft counts as new.

Bifrost reads `pfcd` only after it has checked the token's signature against Microsoft's keys, and exposes it through
`player_account` (API revision 9). The plugin never parses a JWT or looks at anything the client sent.

Bifrost reads `pfcd` as an ISO 8601 UTC time (`2021-03-09T20:36:00.067Z`) or Unix seconds. That is the format PlayFab uses, but check it against a real login before relying on `deny`: if your clients send something else, every login reads as missing a date, and the refusal log line says "of unknown age".

## How it decides

The check runs once per login, on the player's worker, with no allocation, no network and no I/O:

1. `min_age_days = 0` turns the check off.
2. A verified XUID in `exempt_xuids` is admitted. Names never count, and neither does an XUID Xbox didn't verify.
3. No usable date follows `missing_date` (`deny` by default). That covers chain-format logins, offline logins, a token
   without `pfcd`, one that isn't Unix seconds or an ISO 8601 UTC time, and a date more than five minutes in the future.
4. Otherwise the account must be at least `min_age_days` old. A date up to five minutes ahead only absorbs clock drift
   and still counts as a brand new account.

If Bifrost can't answer for the player at all, the login is refused whatever `missing_date` says.

A refused player is held before the backend login and disconnected with `kick_message`. If that disconnect can't be queued,
the login is cancelled instead, and the player sees Bifrost's own "Login rejected".

Every connection goes through admission, so reconnecting is checked again. A backend transfer keeps the same verified
session and isn't a new login, so a refused player never gets far enough to transfer. Players already online when you
raise `min_age_days` are not re-checked until they reconnect.

## Requirements

- Bifrost at API revision 9 or later (2.0.0-rc.18). On an older host the plugin refuses to load rather than skip the check.
- Managed sessions with authentication on. Admission isn't available in passthrough mode, and only one plugin per server can own it.
- A C++23 compiler and CMake 3.20.

## Build and install

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBIFROST_DIR=../Bifrost
cmake --build build --config Release
ctest --test-dir build -C Release
cmake --install build --config Release --prefix ./stage
```

Copy `stage/plugins/AccountGuard.dll` (`.so` or `.dylib` elsewhere) and `AccountGuard.toml` into Bifrost's plugins directory.
`BIFROST_DIR` defaults to a `Bifrost` checkout beside this one.

## Configuration

`AccountGuard.toml` sits beside the library. [`config/AccountGuard.toml`](config/AccountGuard.toml) is the annotated example.
Without the file the defaults apply. A key that is unknown, repeated or out of range stops the plugin from loading.

| Key | Default | Meaning |
| --- | --- | --- |
| `min_age_days` | `30` | Minimum account age in days, 0 to 36500. `0` disables the check. |
| `kick_message` | a short notice | Up to 512 bytes. `{days}` becomes `min_age_days`. |
| `missing_date` | `"deny"` | `"deny"` or `"allow"` for a login with no usable date. |
| `exempt_xuids` | `[]` | Digits-only XUID strings on one line. |

## Adding more account checks later

`AccountAge.hpp` holds the rule as a pure function of the config, the verified XUID, the date and the clock. `AccountGuard.hpp`
is the only place that touches the host. Another check built on Bifrost's `player_account` fits beside `judge` without
touching the glue. `player_account` can grow new fields without breaking plugins built against the older layout.

## Tests

`ctest` runs `tests/Tests.cpp`, which covers the age threshold, invalid, missing and future dates, exemptions, config
parsing (including the shipped example) and the admission outcomes against a fake host: refusal with the custom message,
the cancel fallback, and failing closed.

Bifrost's own suite covers `player_account` and refusal by holding the login and disconnecting.

## License

Apache-2.0, see [LICENSE](LICENSE).
