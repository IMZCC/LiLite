# Web response cookies and expired-main-account re-audit

Reference: PiliPlus `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`

This closes two executable middleware gaps found by tracing the fixed Dart source beyond its page inventory: normal/error web response cookies were discarded, and a server-confirmed expired main account remained selected. The implementation and validation below use synthetic accounts and responses. No real account, login, SMS, account write, signing or installation was used.

## Fixed-source behavior

- `lib/utils/accounts/account_manager/account_mgr.dart`: `_bindRequestAccount` binds the request before sending; non-app requests load URI-scoped cookies from that account. `onResponse` and `onError` both call `_saveCookies` before delivering the result. App REST does not use the web cookie jar.
- `lib/utils/accounts.dart`: selecting a role activates the account before `LoginUtils.onLoginMain`; account import refreshes accounts and runs the main-login check.
- `lib/utils/login_utils.dart:45` and `lib/pages/mine/controller.dart:128`: only an explicit account-not-logged-in result, or a successful user-info response with `isLogin == false`, removes the main account and clears its web login state. `lib/http/api.dart` defines that user-info endpoint as `/x/web-interface/nav`.
- These call chains do not delete the main account after every unrelated service error, mobile-token refusal, risk challenge or network failure.

## Changes and isolation

`Account/WebSessionCookies.swift` stores bounded cookie metadata alongside the Keychain identity, including domain, host/path scope, secure transport and expiry. Request headers follow domain/path boundaries and exclude expired values. Response acceptance validates the actual origin, rejects foreign UID changes and keeps root-session credentials at the account's root domain. The anonymous jar has its own visitor identifier and only accepts visitor cookies; it cannot acquire an authenticated session from an unsolicited response.

`AccountJar.webSession`, `bindWeb`, `webMatches` and `mergeResponseCookies` bind a response to its original UID, raw credentials, device and account routing. Cancellation, a changed role, switching accounts or replacing credentials invalidates a late response. Legitimate auxiliary cookies from concurrent replies merge against the latest jar. Expiry-only and auxiliary updates do not trigger account refresh or repeated nav requests. A root credential rotation is checked with an isolated nav request before publication; any cookies returned by that verification are included too. The verified UID must match the bound account. The returned snapshot describes the actual committed binding.

`Network/WebAccountResponse.swift` is used by `BiliAPI.fetch` and `submitResponse`. It saves valid normal and error response cookies before the business response is decoded. App REST stays on its separate signed, token-only path. An invalid nav for an explicitly selected non-main role still preserves that role's legal response cookies and reports the error without removing another account.

`InvalidWebSession.confirmed` requires HTTP 200 from the official `api.bilibili.com/x/web-interface/nav` endpoint, with `code == -101` or `code == 0` and `isLogin == false`. Only that original binding can revoke the currently selected main account. Cookie processing and removal are one transaction; other stored accounts and unrelated role assignments remain. Main becomes anonymous. Ordinary endpoint `-101`, HTTP failures and risk responses keep the stored main account.

`AccountJar.select` and `mergeArchive` await device activation before `inspectSelectedMain`. Thus the invalid-account check is reached by account selection and import even if the personal page is closed. Offline import and risk challenges preserve the saved account for a later check. Imported credential first-use uses the same narrow invalidation rule. Existing web/mobile proof separation, deduplicated first-use verification and local-cache owner checks remain intact.

`AccountContext` observes confirmed invalidation and refreshes the visible account state. The profile loading path refreshes after the corresponding error. `Discover/SitePage.swift` observes the same event and clears only the embedded browser store belonging to that invalid UID. This store is already nonpersistent; another account's browser state is not cleared.

## Transport and direct web callers

`Network/ResponseCookieOrigin.swift` is a standalone Foundation helper. Every cookie receipt retains its actual response URL. `Network/HTTP11Connection.swift` collects each HTTP/1.1 redirect hop separately. For the URLSession route, `Network/ResponseCookieCapture.swift` records receipts while forwarding redirect, task-completion and TLS challenges to the existing `CertificateSessionDelegate`. Its original redirect policy still decides whether to follow a hop. Final responses are included once. Cookies are never reinterpreted as belonging to the final URL, and no system shared cookie jar is enabled.

The authenticated direct callers now use the same web binding and merge path:

| Area | Updated files |
| --- | --- |
| Dynamic and account reads/writes | `Network/DynamicAPI.swift`, `Network/MomentAccountService.swift`, `Account/ProfileEditor.swift`, `Account/LoginDevices.swift` |
| Messages, notices and publishing | `Social/Compose.swift`, `Social/MessageComposer.swift`, `Social/NoticeService.swift`, authenticated branch of `Social/PublicationCheck.swift` |
| Library, courses and notes | `Library/FolderCover.swift`, `Discover/Courses.swift`, `Discover/NotebookService.swift` |
| Live writes | `Live/LiveComposer.swift`, `Live/LiveInteractionAPI.swift`, `Live/LiveShield.swift`, `Live/LiveVisit.swift` |

The note-image request retains bounded streaming and its explicit clean CDN continuation. Its API response and accepted same-origin redirect receipts use the same collector and original main-account binding. The CDN request does not receive account cookies.

Isolated new-login probes keep their own credential transport. Explicit remote logout retains its reviewed credential comparison and removes that session after acknowledgement. App/gRPC, anonymous visibility checks, public artwork and media/CDN requests do not inherit web-account cookies. Ordinary settings backup mappings were not changed; guest cookie state and credential proofs are not added to account archives.

## Executed checks

`python3 Checks/web_cookies.py` compiles and executes production Cookie/Jar, web-response wrapper and extracted production `BiliAPI.fetch/read/submitResponse` code. Keychain persistence, transport, activation and identity-probe leaves are synthetic. It verifies:

- host/path boundaries, expiry removal without legacy-cookie resurrection, foreign-UID rejection and app exclusion
- production per-request redirect receipt capture, real origin preservation after a different final URL, and unchanged same-origin GET/HEAD versus cross-origin/POST rejection
- actual outgoing scoped headers, normal/error-cookie persistence, core credential rotation and a second rotation from the isolated verifying nav
- concurrent auxiliary replies, expiry-only changes, no refresh notifications for ordinary updates, and cancellation even when transport returns late
- same-UID credential replacement and account/role switches rejecting old replies
- ordinary `-101`, risk and HTTP errors preserving the account; non-main nav errors preserving their own cookie updates
- exact nav invalidation removing only its bound main account, preserving another account/video role, returning main to guest and publishing one invalidation event
- independent visitor cookies, no guest authentication injection, and no guest-state archive export
- activation-before-nav for selection/import, offline/risk preservation and explicit invalidation on those reachable operations

Result: PASS, `dist/web-cookies-check.log`

The existing `bash Checks/imported_credentials.sh` suite passes with the real AccountJar changes, including separate web/mobile proof, expired mobile credentials allowing web and offline use, concurrent proof completion, cancellation, replacement and legacy trusted installation compatibility. `python3 Checks/device_activation.py` passes all four production state, independent payload, runtime adapter and account-publication ordering groups. `python3 Checks/mobile_passport.py` passes its independent Python/OpenSSL signing/encryption oracle, protocol paths, cancellation and token-only identity probes.

Logs: `dist/web-cookies-imported.log`, `dist/web-cookies-activation.log`, `dist/web-cookies-passport.log`

The final arm64 iPhone SDK typecheck covers all 26 changed account/web/transport wrapper primary files against iOS 27.1, including the actual `URLSession.bytes` collector call. Result: PASS, `dist/web-cookies-sdk.log`. The scoped Git whitespace check passes.

## Standalone-source dependencies

- `Checks/web_cookies.py` includes the pure `ResponseCookieOrigin`, `HTTP11Message`, certificate delegate and redirect collector directly, plus the production Cookie/Jar/response sources.
- `Checks/imported_accounts.py` and the two Cookie-backed compilation groups in `Checks/device_activation.py` now explicitly include `Network/ResponseCookieOrigin.swift`. No test verdict or expected behavior was relaxed.
- The existing secure-network, VOD, cast, live-decoder and public-service host harnesses were checked: their Swift input sets do not compile the Network-framework-only `HTTP11Connection.swift` and do not acquire an Account dependency from this change.
- `Checks/run.sh` integration is maintained by the root agent and invokes `python3 Checks/web_cookies.py`.

Online account expiry/cookie rotation and visible WebKit clearing on an iPhone are left to the final real-account acceptance pass. Full transport/media loopbacks and final capture are owned by the root release workflow.
