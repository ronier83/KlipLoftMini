# Contributing to KlipLoft Mini

Thanks for helping make KlipLoft Mini better. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or asking for a feature

[Open an issue](https://github.com/ronier83/KlipLoftMini/issues/new/choose) and pick a template. For bugs,
include your macOS version, the KlipLoft Mini version (Settings › About) and the steps that show the problem.

Please don't paste real clipboard contents into an issue. They can hold passwords, tokens or personal details.
Use made-up text instead.

## Working on the code

1. Fork the repo and create a branch from `main`.
2. Open `KlipLoftMini.xcodeproj` in Xcode 26 or later and run it on macOS 26.
3. To sign with your own team, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`. Never commit
   that file.
4. Keep the change focused: one fix or feature per pull request.
5. Make sure it builds without new warnings, and try it in both Light and Dark Mode.
6. Open a pull request that says what changed and why, with a screenshot for anything visible.

### Code style

- Follow the code around your change: SwiftUI views, `@Observable` models, and small focused types.
- Comment what the code can't say on its own, such as why a workaround exists.
- No analytics, tracking or new network connections. Mini's privacy promise is part of the product.

### What fits in Mini

Mini stays small on purpose: one search bar for your clipboard history. Larger features, like the card drawer,
the iPhone app or the MCP server, belong to [KlipLoft](https://www.kliploft.app). If you're not sure whether
an idea fits, open an issue to talk about it before you write the code.

## Licensing of contributions

KlipLoft Mini is licensed under the [GPL-3.0](LICENSE), and contributions are accepted under the same license.

The official build is also distributed through the Mac App Store. By opening a pull request, you agree that
your contribution may be included in that build, under the App Store's terms, as well as under the GPL-3.0.

## Code of Conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
