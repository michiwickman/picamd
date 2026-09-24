# Contributing to PicaMD

Thanks for being interested in helping. Some quick orientation:

## What's most useful right now

PicaMD is in **public-alpha**. The two highest-impact things you
can contribute:

1. **Bug reports.** Open an issue with:
   - macOS version + Apple silicon vs Intel
   - PicaMD version (`About PicaMD` in the menu)
   - Reproducible steps
   - A screenshot or `.md` snippet that triggers it
2. **Feedback on the AI presets and MCP tools.** They're the
   alpha's two riskiest surfaces — opinions on the default preset
   set, the prompt templates, the MCP tool surface, all welcome.

Less useful (we're not looking for it yet):
- New features. PicaMD is meant to stay a small editor and viewer;
  feature PRs will likely sit. Open an issue to discuss first.
- Refactors that don't fix a bug or simplify code
- Style-only PRs (we follow Swift's standard formatting)

## Building

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
- No third-party Swift packages without strong justification (the
  bundle weight budget is 12 MB; `swift-markdown` and `Sparkle`
  are the only deps right now).

## Project structure

See `README.md` → "Repository layout".

## Sending a PR

1. Fork → branch → commit → push → open PR against `main`.
2. CI runs build + unit tests + bundle-size guard. Green required.
3. Tag a maintainer (currently just one) for review.

## License

MIT. Contributions are licensed under MIT by virtue of submission.
