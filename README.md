<div align="center">

<img src="docs/assets/icon.png" width="128" height="128" alt="KlipLoft Mini icon">

# KlipLoft Mini

**Your clipboard history in one search bar.**

Press <kbd>⌥</kbd> <kbd>Space</kbd>, pick a clip, and it's pasted.<br>
Free, private and open source, from the maker of [KlipLoft](https://www.kliploft.app).

[![Mac App Store: coming soon](https://img.shields.io/badge/Mac_App_Store-coming_soon-0D96F6?logo=apple&logoColor=white)](https://www.kliploft.app)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)](#build-from-source)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Build](https://github.com/ronier83/KlipLoftMini/actions/workflows/build.yml/badge.svg)](https://github.com/ronier83/KlipLoftMini/actions/workflows/build.yml)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/recent-dark.png">
  <img src="docs/assets/recent-light.png" width="460" alt="KlipLoft Mini showing the latest clips under the search bar">
</picture>

</div>

## Coming soon to the Mac App Store

KlipLoft Mini will be free on the Mac App Store. Until then you can [build it from source](#build-from-source)
in a couple of minutes.

## Features

### One search away
- Your latest clips the moment you press <kbd>⌥</kbd> <kbd>Space</kbd>, and your whole history below them
- Search text, titles and keywords as you type, with a live count of the matches
- <kbd>⌘</kbd> <kbd>1</kbd> to <kbd>⌘</kbd> <kbd>0</kbd> paste any of the first ten clips in every list
- Arrow keys or the mouse, whichever you're using

### Filter by type or app
- Narrow results to text, links, images, files or colors
- Or to the app you copied from: Mail, Safari, Notes, Terminal…
- Filters sit in the search as chips; <kbd>Delete</kbd> removes them

### See it before you paste
- Press <kbd>Space</kbd> (or click ⓘ) to preview a clip right in the list
- Edit text right there before you paste it
- Links show their page's title and picture

### Pinboards
- Pin the snippets, replies and links you paste often
- Open your pinboards with the pin button or <kbd>Tab</kbd>, and paste in a keystroke

### Private
- Skips passwords from password managers, and optionally API keys and tokens
- Ignore any app you choose
- Deleted clips are wiped from disk, not just hidden
- No account, no tracking, no ads

### Fast and light
- Lives in the menu bar, with no Dock icon
- Opens instantly, even with 10,000 clips in your history
- Uses next to no energy while you work

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/assets/search.png" width="400" alt="Searching with a Text filter chip"><br><sub>Search with filter chips</sub></td>
    <td align="center"><img src="docs/assets/pinboard.png" width="400" alt="A pinboard"><br><sub>Pinboards</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/preview.png" width="400" alt="Previewing a clip in the list"><br><sub>Preview and edit before you paste</sub></td>
    <td align="center"><img src="docs/assets/recent-dark.png" width="400" alt="KlipLoft Mini in Dark Mode"><br><sub>Light and Dark Mode</sub></td>
  </tr>
</table>

## Mini or KlipLoft?

KlipLoft Mini is the quickest way in. When you want more, [KlipLoft](https://www.kliploft.app) is its bigger
sibling, and it's free too. With the App Store version of Mini, your history and pinboards sync to KlipLoft
through your own iCloud, so they're already there when you switch.

| | KlipLoft Mini | KlipLoft |
|---|:---:|:---:|
| Clipboard history with search | ✓ | ✓ |
| Filters by type and app | ✓ | ✓ |
| Preview and edit before pasting | ✓ | ✓ |
| Pinboards | ✓ | ✓ |
| Skips passwords, wipes deleted clips | ✓ | ✓ |
| iCloud sync between your Macs | App Store version | ✓ |
| Your clips as a drawer of cards, in card styles | | ✓ |
| iPhone and iPad app, with a keyboard that pastes your clips | | ✓ |
| One-click import from Paste or Maccy | | ✓ |
| MCP server, so AI apps can read and build pinboards | | ✓ |
| Open source | ✓ | |

<div align="center">

<a href="https://www.kliploft.app"><img src="https://img.shields.io/badge/Get_KlipLoft-free-FF6B35?style=for-the-badge&logo=apple&logoColor=white" alt="Get KlipLoft, free" height="42"></a>

</div>

Settings › About in Mini has the same link.

## Privacy

Your clips never leave your Mac, except to your own private iCloud database when sync is on in the App Store
version (the developer can't read it). There are no analytics, crash reports, ads or accounts.

The one other connection is link previews: when you copy a link, Mini fetches that page's title and picture
directly from the site. You can turn this off in Settings › Clips.

Direct Paste, which presses <kbd>⌘</kbd> <kbd>V</kbd> for you, is off by default. It's the only feature that
asks for Accessibility access.

## Build from source

You need a Mac with **macOS 26** and **Xcode 26** or later.

```sh
git clone https://github.com/ronier83/KlipLoftMini.git
cd KlipLoftMini
open KlipLoftMini.xcodeproj
```

Then choose **Product › Run** (<kbd>⌘</kbd> <kbd>R</kbd>).

To sign with your own Apple developer team, copy the example config and fill it in. Your copy is git-ignored.

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Or build from the command line without signing:

```sh
xcodebuild -project KlipLoftMini.xcodeproj -scheme KlipLoftMini -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Builds from source keep their history on your Mac. iCloud sync needs KlipLoft's iCloud container, which only
the App Store version can use, so Mini detects this and hides the iCloud setting.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first, and
report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

KlipLoft Mini is free software under the [GNU General Public License v3.0](LICENSE).
© 2026 Ron Erez.
