# Smolish for iOS

Native SwiftUI client for Smolish. The current MVP includes the public vertical video feed, cursor pagination, native video playback, official Smolish branding, cookie-based development authentication, notifications, and Studio.

## Development authentication

The Profile tab accepts the complete `Cookie` request-header value from an already signed-in `smolish.com` browser session. It extracts only the exact `__Secure-better-auth.session_token` pair; Cloudflare and multi-session cookies are discarded. The value is stored in the device Keychain and attached only to Smolish API requests. Treat this value like a password. Remove it with **Profile → Remove cookie and sign out** when finished.

This is a temporary development workflow. Production should replace it with the planned Better Auth native token exchange.

## Current features

- Live paginated For You feed
- Personalized feed state when a Keychain session cookie is available
- Tap-to-pause looping video and separate mute control
- Persistent play/pause control in the video action rail
- Native share sheet using canonical `https://smolish.com/v/{id}` links
- Authenticated likes and bookmarks
- Native comments with pinned comments, pagination, and authenticated posting
- In-app notifications, unread badge, pull-to-refresh, and 60-second polling
- Studio analytics using the live analytics endpoint, 7/30/90-day ranges, KPI cards, a views trend chart, and uploaded-video metrics
- No messaging implementation

## Requirements

- Xcode 26 or newer
- iOS 17 or newer

## Backend integration note

The website currently authenticates through Better Auth HttpOnly cookies. Native sign-in should use a short-lived mobile authorization code or Better Auth bearer/one-time-token integration so credentials can be stored in Keychain and used by `URLSession`.
