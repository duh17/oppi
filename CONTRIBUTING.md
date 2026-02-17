# Contributing

Oppi is a personal project. The code is open source for transparency, learning, and so others can run it — not because I'm actively seeking contributions.

That said, if you find a bug or have a useful idea:

- **Bug reports** — Open an issue with steps to reproduce. Include server logs and iOS os_log output if relevant.
- **Security issues** — See [SECURITY.md](SECURITY.md) for responsible disclosure. Do not open public issues for security vulnerabilities.
- **Ideas** — Discussions are welcome. I may or may not build it, but I read everything.
- **Pull requests** — I'll review them, but no guarantees on merge timeline. If it's a large change, open an issue first to discuss.

## Building from Source

### Server

```bash
cd server
npm install
npm test          # 1,000+ tests
npm run dev       # Start with auto-reload
```

### iOS

Requires Xcode 26.2+ with iOS 26 SDK.

```bash
cd ios
brew install xcodegen   # if needed
xcodegen generate
xcodebuild build -scheme Oppi -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild test -scheme Oppi -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

**Fork setup:** Update `bundleIdPrefix` and `DEVELOPMENT_TEAM` in `ios/project.yml` to your own Apple Developer values.

## Code Style

- **Server:** TypeScript, enforced by ESLint + Prettier via `npm run check`
- **iOS:** Swift, SwiftLint configured in project
- **Commits:** Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`)
