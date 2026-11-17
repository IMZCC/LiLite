# Session and HTTP middleware re-audit

Reference: PiliPlus commit `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`

This review follows the executable account/middleware paths in the fixed Dart source, including behavior outside the page inventory. It supplements the frozen surface re-audit. No account login, phone operation, signing, device-information collection, or live device-activation request is used by these checks.

## Device activation

The original `lib/http/init.dart:61` builds a JSON `payload` for `/x/internal/gaia-gateway/ExClimbWuzhi`. The nested keys are `3064`, `39c8`, and `3c43`; its canvas suffix is generated random data, not a device screenshot. `lib/utils/accounts.dart:36` activates the distinct accounts used by the four roles after loading saved accounts. Its role setter and account import reach the same activation function. `LoginAccount.activated` is an in-memory flag, not an archive field. The original marks that flag before sending; the native implementation waits for a successful service response so a failure remains retryable.

`lib/utils/accounts/account.dart:202` also initializes anonymous web cookies through `/x/frontend/finger/spi`, preserving `b_3`, `b_4`, and `b_nut`; the fallback creates a local `buvid3`. A newly constructed login account ensures it has a `buvid3` too. The anonymous account starts with `activated = true`, so the original activation guard ordinarily skips the anonymous POST. Native guest initialization and activation therefore use a distinct guest cookie binding, never the active account's credentials.

Native request/state implementation: `Network/DeviceActivation.swift`; runtime/Jar adapter: `Account/DeviceActivationContext.swift`. The iOS platform field uses `UIDevice.systemName`, `systemVersion`, and `model`. It does not claim Android hardware or use a user's device name, screenshot, advertising identifier, or vendor identifier. Random canvas noise is not part of the completion identity.

The synthetic production-code check `python3 Checks/device_activation.py` verifies the exact POST URL, body, content type, account/guest headers and an independent Python oracle for the nested payload and canvas suffix. It exercises success-only completion, subsequent retry after HTTP/protocol refusal, legitimate cookie rotation, unrelated store revisions, pre/post-send UID/token/device/role changes, concurrent request coalescing, explicit cancellation, removal from the selected role set, and replacement of an obsolete in-flight request. It does not invoke an actual device provider or a network transport.

The same check runs the production `DeviceActivationService` and context adapter with synthetic secure-store/identity-probe/transport leaves and the real `WebSessionCookies` model. It verifies four-role account deduplication, anonymous SPI without account headers, failure keeping the guest's local fallback, failure not blocking a named account, cookie rotation marking the returned new binding, auxiliary cookie updates not invalidating an account through a coarse generation counter, URI-scoped device-cookie changes invalidating the exact request binding, replacement mobile tokens, removal/reselection of a pending role owner, and a late guest response after switching main accounts. Only the guest jar receives its SPI cookies.

## Non-login risk verification

`lib/http/validate.dart` implements the two gaia verification endpoints. `lib/utils/request_utils.dart:540` contains a register → Geetest dialog → validate → callback helper. A whole-`lib` call-site search finds its external search call only as a commented statement at `lib/http/search.dart:99`. The actual `v_voucher` branch returns a risk error. The search controller has a success callback and delayed reload, but this helper has no executable caller linking it to the search response. The reviewed middleware does not present another non-login `-352`/`-412` captcha dialog or automatic validation/retry chain. This is not an omitted executable original flow; native search retains its visible verification continuation and the native login captcha/risk exchanges are separate reachable flows.

## WBI key lifecycle

`lib/utils/wbi_sign.dart:78–116` obtains the nav WBI keys when no usable daily cache exists and signs the outgoing query. There is no interceptor invalidating the cache and re-signing after a service refusal. Native `BiliAPI.sign` likewise refreshes missing or previous-day keys and uses `WebQuery` to mix/sign the query. The original has no additional error-triggered WBI renewal operation to port.

## Stored refresh tokens

The fixed source stores `tokenInfo['refresh_token']` in `lib/pages/login/controller.dart:616`; the account model and archive adapter preserve it. A whole-`lib` search finds no OAuth refresh request, cookie refresh exchange, scheduler, or retry interceptor consuming that saved value. Native archives preserve `archiveRefresh` and the native login exchange saves its returned refresh token. A new automatic refresh protocol is not claimed as an original feature.

## Cookie updates and explicitly expired main accounts

The original `AccountManager` attaches the bound non-app account's URI-scoped cookies, saves response `Set-Cookie` values before normal delivery, and also saves cookies for error responses. Its app REST branch uses AppSign/access-key without the web cookie jar. This audit identified that native normal responses previously discarded returned cookies. The native path is now `BiliAPI.fetch/submitResponse` → `WebAccountResponse` → the bound `AccountJar.mergeResponseCookies`, with an independent guest cookie context and URI-scoped cookie metadata. Account-data validation and regression results are recorded in [the Cookie and expiry re-audit](reaudit-2026-11-13-cookies.md).

`LoginUtils.onLoginMain` (`lib/utils/login_utils.dart:45`) and `MineController.queryUserInfo` (`lib/pages/mine/controller.dart:128`) explicitly delete a main account after the service confirms it is no longer logged in. Other network errors do not mean the account should be removed. Native `InvalidWebSession.confirmed` is restricted to the official nav response; ordinary endpoint errors do not delete an account. `AccountJar.inspectSelectedMain` handles account selection/import and `WebAccountResponse` handles the corresponding nav response, while narrow cookie updates are preserved for other bound accounts. The same Cookie and expiry re-audit records the owning implementation and tests.

## Retry and connection policy

The original `RetryInterceptor` excludes streams, follows configured redirects (303 becomes GET), and retries configured connection failures with an increasing delay. It does not add a hidden captcha or credential-refresh exchange. Native `ConnectionRetry` retains the configured count and linear delay for eligible reads; mutating operations are not silently repeated. Native proxy, HTTP protocol selection, redirect handling and the explicitly optional certificate-validation setting use the shared transport policy described in `http-transport-trust.md`. Network-framework connections and URLSession handle connection changes using their native mechanisms; no Android connectivity adapter is embedded.

## Integration result

The activation implementation and its checks are complete. `AccountContext.refresh` awaits initialization before publishing the new account state. A refresh UUID and task-cancellation check prevent an obsolete refresh from publishing a newer account while that newer account's initialization is still pending. The production refresh body is executed with an injected activation leaf to verify waiting, overlapping refreshes and cancellation, rather than asserting source text.

`AccountJar.select` and `mergeArchive` await activation before `inspectSelectedMain`, matching the original activation → main-login/nav sequence. `AccountContext.refresh` subsequently reaches the same service; stable session/device completion keys suppress duplicate POSTs. Account loading, native/password/SMS/QR login completion, web/Cookie login, account-role changes, account archive/data-pack restore, device-identifier changes and local reset all reach the refresh path. Anonymous SPI is separate and carries no Cookie, account UID, access key, or mobile device header. There is no activation → `BiliAPI.fetch` recursion and normal response-cookie updates do not schedule account refresh loops.

After each request, the adapter uses the cookie merge's returned snapshot to construct the successful new identity. It never fetches a newer unrelated credential and marks that one activated. Completion compares actual UID, device, stable URI-specific session cookies and access key; routing is also checked for in-flight work. The store generation is captured for audit/context, but unrelated account writes and legitimate auxiliary cookie updates do not invalidate a matching session.

Executed `python3 Checks/device_activation.py`: all four production request/state, independent payload, runtime service and account-publication ordering checks pass. The actual iOS provider, activation files, `Accounts`, `WebSessionCookies`, `WebAccountResponse` and `BiliAPI` were typechecked as arm64 iPhone code against the iOS 27.1 SDK. The final SDK log is `dist/reaudit-2026-11-13/device-activation-sdk.log`.

No activation request or SPI request was sent to the service during this validation. Signed delivery and device interaction remain the parent release workflow; this evidence does not alter existing release receipts or the frozen surface report.
