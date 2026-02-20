# Contributing

Bug reports and ideas welcome — open an issue.

Pull requests reviewed but no merge timeline guaranteed. For large changes, open an issue first.

## Build from source

### Server

```bash
cd server
npm install
npm run build
npm test
npm run check   # typecheck + lint + format
```

### iOS

Requires Xcode 26.2+ with iOS 26 SDK.

```bash
cd ios
brew install xcodegen
xcodegen generate
xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Update `bundleIdPrefix` and `DEVELOPMENT_TEAM` in `ios/project.yml` to your own Apple Developer values.

## Commits

Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
