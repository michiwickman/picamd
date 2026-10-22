# Contributing to PicaMD

Thanks for being interested in helping. Some quick orientation:

## What's most useful right now

PicaMD is a small project with one maintainer. The two most useful
contributions:

1. **Bug reports.** Open an issue with:
   - macOS version and Mac model
   - PicaMD version (`About PicaMD` in the menu)
   - Reproducible steps
   - A screenshot or `.md` snippet that triggers it
2. **Feedback on the AI presets and MCP tools.** Opinions on the
   default presets, the prompt templates and the MCP tool surface are
   welcome.

Less useful (we're not looking for it yet):
- New features. PicaMD is meant to stay a small editor and viewer;
  feature PRs will likely sit. Open an issue to discuss first.
- Refactors that don't fix a bug or simplify code
- Style-only PRs (we follow Swift's standard formatting)

## Building

You need macOS 27 and Xcode 27 or later.

```bash
brew install xcodegen
git clone https://github.com/michiwickman/picamd.git
cd picamd
./build.sh           # build + ad-hoc sign + install to /Applications
xcodegen generate    # if just opening in Xcode
```

To run the unit suite (the main bundle plus the MCP-sidecar
bundle), invoke each bundle separately. `xcodebuild test` against the scheme will
eventually run both, but it serialises them with a long delay
between (~30 min in observed runs); two separate invocations
finish in seconds:

```bash
# Main bundle (host-attached to PicaMD.app)
xcodebuild -project PicaMD.xcodeproj -scheme PicaMD \
  -destination 'platform=macOS' \
  -only-testing:PicaMDTests test

# MCP sidecar bundle (library-style)
xcodebuild -project PicaMD.xcodeproj -scheme PicaMD \
  -destination 'platform=macOS' \
  -only-testing:PicaMDMCPTests test
```

CI does both. Tests must pass before you push.

## Code conventions

- Swift 6 strict concurrency throughout. Apple frameworks are
  `@MainActor`-isolated; long-running work lives in
  `Task.detached` with explicit `MainActor.run` hops back.
- Prefer fewer, fatter files over a sea of one-class files. Pull
  things apart only when reuse demands it.
- Comments answer **why**, not what. Mechanical paraphrase of code
  is noise.
- No third-party Swift packages without strong justification (CI
  fails a Release bundle above `BUNDLE_SIZE_LIMIT_MB` in
  `.github/workflows/ci.yml`; `swift-markdown` and `Sparkle` are the
  only deps right now).

## Project structure

```
project.yml          xcodegen spec (generates PicaMD.xcodeproj)
build.sh             local Release build, INSTALL=0 skips /Applications
release.sh           Release build, sign, zip into dist/
PicaMD/              the app: SwiftUI shell, menus, settings, welcome
PicaMD/Editor/       the text view, highlighter, overlays, AI, themes
PicaMD/Search/       find bar and search
PicaMD/Settings/     the Settings panes
PicaMDQuickLook/     Quick Look preview extension
PicaMDMCP/           MCP sidecar (`picamd-mcp`) for Claude Code
PicaMDTests/         app unit tests (hosted in PicaMD.app)
PicaMDMCPTests/      sidecar unit tests
samples/             Welcome.md and test documents
design/icon/         app icon source and generator (see its README)
.github/             CI, release workflow, issue templates
```

## Sending a PR

1. Fork → branch → commit → push → open PR against `main`.
2. CI runs build + unit tests + bundle-size guard. Green required.
3. Ask for a review in the PR.

## License

MIT. Contributions are licensed under MIT by virtue of submission.
