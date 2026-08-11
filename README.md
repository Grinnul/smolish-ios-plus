# Smolish for iOS

An iOS client for the Smolish service, written in SwiftUI. This repository preserves the V2 codebase for learning, experimentation, and further development.

> **Project status:** archived. The original App Store distribution has ended and this repository is provided as source code. It is not an official Smolish project. Before redistributing a build, review Smolish's current terms and obtain any permissions you need for its name, branding, assets, and services.

## What is included

- A vertical, cursor-paginated **For You** feed with native video playback
- Browse user profiles and search for creators
- Likes, follows, bookmarks, comments, replies, mentions, and comment reactions when signed in
- Notifications with unread count, pull-to-refresh, and periodic refresh while the app is running
- **Studio**: creator analytics, 7/30/90-day ranges, uploaded-video metrics, video uploads, and video metadata editing
- A native share sheet using canonical video URLs
- A SwiftUI app with an iOS 17 deployment target and no third-party package dependencies

The app uses `https://smolish.com` as its API and web-authentication endpoint. Some features depend on endpoints, cookies, and behavior outside this repository; they may stop working if that service changes.

## Requirements

- macOS with **Xcode 26 or newer**
- An iPhone, iPad, or Simulator running **iOS 17.0 or newer**
- An Apple ID and developer signing team to install on a physical device
- A valid Smolish account only if you want to test signed-in features

## Build and run

1. Clone the repository:

   ```bash
   git clone https://github.com/mtxben/smolish-ios.git
   cd smolish-ios
   ```

2. Open `Smolish.xcodeproj` in Xcode.
3. Select the **Smolish** scheme and an iOS 17+ simulator or a connected device.
4. For a physical device, open the target's **Signing & Capabilities** settings and select your own development team. Xcode may require a unique bundle identifier for your account.
5. Press **Run** (`⌘R`).

There are no CocoaPods, Swift Package Manager packages, or environment files to install. The project currently targets Swift 5 and uses Apple frameworks such as SwiftUI, WebKit, AVFoundation, and Security.

## V2 authentication and account switching

V2 replaces the V1 manual-cookie setup with an in-app web sign-in flow. It still ultimately uses the website's authenticated browser session; it does **not** add a standalone native OAuth/token API.

### Sign in without manually pasting a cookie

1. Open the **Profile** tab and choose **Connect your Smolish account**.
2. The app opens a persistent in-app Smolish web view. Use the website's normal sign-in method (for example, Google or email).
3. After the website confirms the session, the app reads the signed-in profile and transfers the applicable `smolish.com` cookies plus the web view's User-Agent to its local session store.
4. The app stores those values in the iOS Keychain and attaches them to authenticated API requests.

This is why V2 feels cookie-free to the person using the app: they no longer have to find and paste a browser `Cookie` header or User-Agent themselves. The underlying web session is still required and may expire, be rejected, or change if Smolish changes its authentication implementation.

### Multiple accounts

V2 uses Smolish's web account endpoints and the in-app browser session to discover and switch accounts.

1. From **Profile**, select **Switch Smolish account**.
2. Choose an existing connected account to make it active, or choose **Add another account**.
3. To add one, the web view opens Smolish; use the website's account switcher and complete sign-in for the additional account.
4. The app refreshes its saved browser cookies and updates its native request session to match the selected account.

The UI allows up to ten connected accounts, matching the limit exposed by the service. During a switch or background session maintenance, authenticated requests are held briefly to avoid using a partially switched session. An expired account must be signed in again through the web flow.

### V1 fallback

The V1 manual flow remains available from Profile as **Use V1 manual cookie fallback**. It accepts a complete `Cookie` request-header value and a browser User-Agent from the same signed-in session. Both are sensitive credentials: never put them in an issue, screenshot, commit, or chat message. Use **Remove cookie and sign out** to erase locally stored session data.

## How the app is organized

| Area | Main location | Purpose |
| --- | --- | --- |
| App startup and tabs | `Smolish/SmolishApp.swift`, `Smolish/RootTabView.swift` | Creates shared session, notification, and web-auth objects. |
| API requests | `Smolish/Services/APIClient.swift` | Calls the Smolish API and applies the saved browser session to authenticated requests. |
| Session storage | `Smolish/Services/SessionStore.swift` | Stores the cookie header, User-Agent, and persisted browser-cookie jar in Keychain. |
| Web sign-in / multi-account | `Smolish/Services/WebAuthenticationStore.swift` | Hosts the persistent `WKWebView`, detects sign-in, and switches web accounts. |
| Feed | `Smolish/Features/Feed/` | Feed paging, playback controls, and feed interactions. |
| Profile | `Smolish/Features/Profile/ProfileView.swift` | Profile display, sign-in, account switching, and the V1 fallback. |
| Notifications | `Smolish/Features/Notifications/` | Notification list and unread state. |
| Studio | `Smolish/Features/Studio/` | Analytics, uploads, and video management. |

## Data and security notes

- Authentication material is saved with Keychain accessibility `AfterFirstUnlockThisDeviceOnly`; it is not written to the repository or a plaintext settings file.
- The API client uses an ephemeral `URLSession` and disables shared cookie storage. It explicitly adds the saved browser headers only for Smolish requests that need them.
- The persistent web view keeps its own applicable `smolish.com` cookies so website authentication and native API requests can stay in sync.
- Do not log request headers or upload a device backup containing active credentials.

## Troubleshooting

| Problem | What to try |
| --- | --- |
| Signing fails or appears stuck | Check your connection, finish sign-in in the in-app web view, then reload or open Profile again. |
| Account is marked expired | Open the account switcher and sign in to that account again. |
| An authenticated action returns an error | Remove the session, sign in again, and confirm that the corresponding Smolish endpoint still exists. |
| Build cannot install on a device | Select your own Xcode signing team and use a unique bundle identifier. |
| API decoding fails | The remote API response may have changed. Inspect `APIClient.swift` and the related model before adapting the decoder. |

## Contributing or forking

Issues and pull requests are useful for documentation, maintainability, and improvements that can be tested without misrepresenting the app as official. If you create a derivative or publish a build, give it its own name and visual identity, remove any third-party branded assets you are not authorized to use, and make its independent status clear to users.

Before opening a pull request, build the app in Xcode against an iOS 17+ destination. Do not commit secrets, cookies, User-Agent values, signing certificates, provisioning profiles, or generated user data.

## Known limitations

- No messaging implementation is included.
- Authentication relies on the remote website's cookies and may require maintenance when its login or Cloudflare behavior changes.
- The service API is not versioned by this repository; endpoint and response changes can break features without a source-code change here.
- This archived project is not supported or distributed through the App Store.
