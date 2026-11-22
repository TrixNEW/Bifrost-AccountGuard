# AccountGuard

AccountGuard checks the age of a Minecraft PlayFab account before [Bifrost](https://github.com/TrixNEW/Bifrost) forwards the login to a backend. Bifrost reads the creation date (`pfcd`) from a Microsoft-verified token. The date refers to the Minecraft PlayFab title account.

## Install

Build with Zig 0.17.0 and copy the library and `AccountGuard.toml` from `zig-out/plugins` to Bifrost's plugins directory.

```sh
zig build -Doptimize=ReleaseFast
zig build test
```

AccountGuard requires Bifrost 2.0.0-rc.18 or later (API revision 9). Enable managed sessions and authentication to enforce account age. Bifrost grants admission control to one plugin per server. AccountGuard skips registration and leaves admission control available when `min_age_days` is zero.

## Configuration

The optional [AccountGuard.toml](config/AccountGuard.toml) sits beside the library. A missing file uses the defaults. Unknown keys, duplicate keys, and invalid values stop the plugin from loading.

| Key | Default | Meaning |
| --- | --- | --- |
| `min_age_days` | `30` | Minimum age in days, from 0 to 36500. Zero disables the check. |
| `kick_message` | See example | UTF-8 message, 1 to 512 bytes. The first `{days}` is replaced with the configured minimum. |
| `missing_date` | `"deny"` | `"deny"` or `"allow"` for logins without a usable creation date. |
| `exempt_xuids` | `[]` | One-line list of quoted numeric XUIDs. An exemption requires a verified online identity. |

Verified exemptions skip the age lookup. For everyone else, offline logins, tokens without a usable date, and dates more than five minutes ahead follow `missing_date`. A date within five minutes ahead counts as a new account. A failed required host lookup always rejects the login.

AccountGuard holds refused logins and asks Bifrost to disconnect them with the configured message. If Bifrost cannot queue the disconnect, it cancels admission with its standard rejection message. Reconnects are checked again. Backend transfers reuse the admitted session.

Run `zig build test` to check parsing, verified identity, age boundaries, and admission outcomes.

[Apache-2.0](LICENSE)
