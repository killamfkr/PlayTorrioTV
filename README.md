# PlayTorrio TV

Android TV app for streaming movies, shows, music, and audiobooks. Built with Flutter, controlled entirely with a TV remote.

---

## What it does

- **Torrent streaming** — pick a source, it streams instantly via the built-in torrent engine. No need to wait for downloads.
- **Debrid support** — plug in your Real-Debrid or TorBox API key and stream cached torrents as direct links instead.
- **Stremio addons** — add your addon URLs in settings. Their catalogs show up in the app and streams appear alongside torrent sources.
- **TMDB everything** — home screen pulls trending/popular/top rated from TMDB. Search finds movies and shows. Details page shows cast, seasons, episodes.
- **Continue watching** — picks up where you left off automatically.
- **Music** — search and play tracks via Deezer. Playlists, liked songs, shuffle, loop, speed control.
- **Audiobooks** — pulls from Tokybook, Golden Audiobook, and others. Chapter playback with speed control and auto-resume.
- **Multiple profiles** — up to 5, each with their own watch history, settings, and library.
- **VLC player** — native player with subtitle fetching (multiple sources), audio track switching, aspect ratio toggle, and D-pad seeking.
- **Auto-updates** — checks GitHub releases on startup, downloads and installs the right APK for your device.

---

## Install

Grab the APK from [Releases](https://github.com/ayman708-UX/PlayTorrioTV/releases):

- `app-arm64-v8a-release.apk` — most devices
- `app-armeabi-v7a-release.apk` — older 32-bit devices

```bash
adb install app-arm64-v8a-release.apk
```

---

## Build

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

---