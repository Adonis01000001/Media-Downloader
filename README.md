# Gather

Gather is an Android 10+ (API 29+) Flutter app for saving media that a platform publicly exposes or returns through an account’s official API. It registers as a text-share target, detects supported links automatically, previews available items, and saves permitted downloads to Android MediaStore. No ads, telemetry, platform passwords, private-page scraping, or access-control bypasses.

## Current platform capabilities

| Platform | Current media support | Authorized/private account behavior | Connection / requested permissions |
| --- | --- | --- | --- |
| Instagram | Public photos, videos, and carousels; connected Professional account’s own photos/videos/carousels through `/me/media` | Own Professional account only. No media from accounts the user follows. | Instagram Login OAuth; `instagram_business_basic` only. |
| X | Public photos, MP4 videos, and multi-media posts through the existing no-cookie public renderer. Connected-account lookup uses X API v2 and can save photo/video URLs only when the official response supplies an allowed direct media URL. | Conditional only: a post is considered authorized-private when the authenticated API returns its author as protected and supplies downloadable media. The app does not infer access from a follow relationship. This has not been live-tested with developer credentials; Settings does not advertise protected access until such a response is observed. A 401/403/404 is surfaced without renderer fallback. | OAuth 2.0 authorization code with PKCE; `tweet.read`, `users.read`, `offline.access`. |
| Pinterest | Public Pin image and progressive MP4 video | Public-only. Secret Pins are not accessed. | No account connection in this build. |
| TikTok | Public title/creator/thumbnail preview only; there is no download action | No authorized private-media path. | Public oEmbed preview; no OAuth scopes. |
| Facebook | URLs are recognized, but post metadata/media extraction and downloads are unavailable in this build | No Facebook access is claimed. | No Facebook OAuth or Graph API permissions requested. |
| YouTube | Video URLs are recognized, but audiovisual downloads are disabled | No authorized private-media path. | No YouTube OAuth scopes requested. |

Pinterest and the public X/Instagram paths preserve the existing public-only extractors. They do not use account sessions. The TikTok Display API provides public video metadata/embed information, not a video file. Facebook Page tokens can represent Pages a user manages, but this build does not implement a reviewed Graph API media reader. YouTube downloads are disabled unless Gather receives prior written approval to do so.

The access classification is carried with each resolved post: `public`, `ownAccount`, or `authorizedPrivate`. Instagram’s authorized path is always `ownAccount`; X’s `authorizedPrivate` state is set only after the authenticated API returns a protected post. A connected account or OAuth token by itself does not grant or imply access.

Official API references: [Instagram API for Professional accounts](https://www.postman.com/meta/workspace/instagram/documentation/23987686-9386f468-7714-490f-9bfc-9442db5c8f00), [X post lookup and media fields](https://docs.x.com/x-api/posts/get-post-by-id), [X OAuth 2.0](https://docs.x.com/fundamentals/authentication/oauth-2-0/overview), [TikTok Display API](https://developers.tiktok.com/docs/en/display-api-overview), [Meta Facebook Graph API collection](https://www.postman.com/meta/facebook/documentation/r56bjfd/facebook-api), and [YouTube developer policies](https://developers.google.com/youtube/terms/developer-policies).

## Use and storage

Share an X, Instagram, Pinterest, TikTok, Facebook, or YouTube HTTPS link with **Gather**, or paste it on the Save screen. Supported links are routed automatically. Review returned media, select an available quality, optionally rename a file, and queue one item or the full post. The Settings screen lists each provider’s current capabilities and connection state.

Images go to `Pictures/Gather/` and videos to `Movies/Gather/` through MediaStore, so Gallery/Photos apps can index them. Settings can use Android’s Storage Access Framework to select a writable folder, including an SD-card folder when the system picker permits it. Gather does not claim `ACTION_VIEW` for platform links; normal taps continue to open the platform app or browser.

WorkManager queues survive normal app closure and device restart. Android may delay background jobs; a force-stop pauses jobs until Gather is opened again. Wi-Fi-only applies to new jobs. Failed network transfers use exponential retry. Files are staged privately, checked, then written to the selected destination. Names default to `Account Name - Post Title`, are sanitized, and receive a numeric suffix when needed. MediaStore records the download completion timestamp. Maximum file size is 2 GB. History retains up to 500 finished jobs plus active jobs.

## Provider architecture

`PlatformProvider` defines `authenticate`, `disconnect`, `getCurrentUser`, `resolveSharedUrl`, `getPost`, `getMedia`, `downloadMedia`, and capability data. `PlatformProviderRegistry` detects the URL’s platform and delegates to its provider. The UI uses this common contract; it does not build platform API requests. A common native download queue handles progress, duplicate detection, filenames, and gallery registration.

- `InstagramProvider` wraps the existing Instagram Login OAuth and exact-permalink search of the authenticated account’s `/me/media`. It keeps the existing carousel handling, OAuth state validation, protected backend handoff, token refresh, revoked-access handling, and rate-limit/network errors.
- `XProvider` uses the official user-authenticated X API for connected-account link lookup. If no X account is connected, it retains the existing public-only X renderer path. If the official API denies or cannot return a connected account’s post, Gather does not try the renderer.
- `PinterestProvider` and `TikTokProvider` preserve their current public behavior. TikTok items are explicitly preview-only.
- `FacebookProvider` and `YouTubeProvider` recognize supported URL patterns and return specific unavailable/restricted errors. They do not have a scraper fallback.

Capabilities are represented by `PlatformCapabilities` (`canAuthenticate`, `canResolvePosts`, `canAccessOwnMedia`, `canAccessAuthorizedPrivateMedia`, image/video download support, carousel support, and official API support). X’s protected-media capability remains false until the authenticated API actually returns protected content and a downloadable source for the current session.

## OAuth setup

Gather never accepts platform passwords. OAuth client secrets belong only in the backend’s environment. OAuth sessions and short-lived handoff values are encrypted on Android with AES-GCM and Android Keystore; Instagram and X use separate storage namespaces and keys. The backend holds only expiring in-memory OAuth attempt/handoff state, returns each session once, and does not persist or proxy media tokens. OAuth state, callback URI, authorization code response, granted scopes, and X account identity are validated server-side.

### Instagram

Create/configure a Meta app for Instagram Login and an eligible Professional Business or Creator account. Register exactly `https://YOUR_HOST/v1/instagram/oauth/callback`. Gather requests only `instagram_business_basic`. This API path can see only media listed for the connected Professional account itself; a post absent from that account’s API list remains unavailable.

### X

Create an X developer app with OAuth 2.0 user authentication. Register exactly `https://YOUR_HOST/v1/x/oauth/callback` and enable the official API access needed for Post lookup. Gather requests only `tweet.read`, `users.read`, and `offline.access`; it uses PKCE S256. These read permissions identify the account, look up a shared post, and refresh authorization. It requests no posting or write permission.

Configure the Node backend. `.env.example` is in `backend/`; copy it to `backend/.env`, fill in the app IDs/secrets and exact callback URLs, and keep HTTPS in front of the service. The server defaults to loopback (`127.0.0.1`) for a same-host HTTPS reverse proxy. OAuth attempt state is in memory, so run one backend instance unless a shared state store is added.

```powershell
Set-Location backend
Copy-Item .env.example .env
# Edit .env with Meta and/or X credentials and the registered HTTPS callback URLs.
node --env-file=.env server.mjs
```

Build with the backend’s public HTTPS origin. Omit a provider’s define to keep its sign-in button unavailable; public features continue to work.

```powershell
Set-Location ..
flutter build apk --debug `
  --dart-define=INSTAGRAM_AUTH_SERVER=https://oauth.example.com `
  --dart-define=X_AUTH_SERVER=https://oauth.example.com
flutter build apk --release `
  --dart-define=INSTAGRAM_AUTH_SERVER=https://oauth.example.com `
  --dart-define=X_AUTH_SERVER=https://oauth.example.com
```

Meta/X app review, API access tiers, redirect registration, platform behavior, and terms are controlled by the providers. No live OAuth or protected-post test can be completed until the owner configures approved developer apps and HTTPS callback infrastructure. Never put `INSTAGRAM_APP_SECRET` or `X_CLIENT_SECRET` in Flutter build defines or source files.

## Build, tests, and signing

```powershell
flutter pub get
flutter analyze
flutter test
Set-Location backend
npm test
Set-Location ..
flutter build apk --debug
flutter build apk --release
```

APK outputs: `build/app/outputs/flutter-apk/app-debug.apk` and `app-release.apk`. Release builds use the generated RSA-3072 sideload key at `.keys/gather-release.jks`; passwords and alias are in ignored `android/key.properties`. Keep both private and preserve this key for future updates. Debug and release have different certificates; uninstall the debug app before installing release on the same device.

## Tests

- `test/extractors_test.dart`: hostile URL boundaries, public X photos/video qualities, Instagram carousel, Pinterest identity/original variants, TikTok preview-only behavior, and safe filenames.
- `test/instagram_api_test.dart` and `test/instagram_auth_test.dart`: exact own-account media matching, carousel mapping, refresh/revocation behavior, OAuth state and handoff.
- `test/x_api_test.dart`: X public/own/protected API response mapping, media sets, token refresh, rate limits, deleted/denied posts, no API-denial fallback, capability truthfulness, and Facebook/YouTube link routing.
- `backend/instagram_oauth.test.mjs` and `backend/x_oauth.test.mjs`: mocked platform responses, state/PKCE, exact scopes, account identity, one-time handoff, refresh, and revocation. Automated tests use no real platform credentials.
- `test/widget_test.dart`: phone-sized Save, Library, Settings, and invalid-link handling.

## Android permissions and privacy

Android permissions are `INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS` (requested at download time on Android 13+), `FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_DATA_SYNC`. WorkManager supplies scheduling permissions such as `WAKE_LOCK` and `RECEIVE_BOOT_COMPLETED`. MediaStore writes created by Gather do not require broad storage permission on Android 10+. User-selected folders use persisted SAF grants. No broad storage, package enumeration, accessibility, contacts, or SMS permissions are requested. Android app backup is disabled.

## Personal use and distribution

Save only content you own or have permission to save. Users are responsible for copyright and each platform’s terms. Public availability is not a copyright license. Do not distribute Gather through an app store without reviewing current platform and store policies. This sideload build does not claim Play Store eligibility or platform approval.
