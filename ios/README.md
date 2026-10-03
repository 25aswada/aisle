# Aisle iOS

SwiftUI app (iOS 17+). The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); the generated `Aisle.xcodeproj` is
committed so XcodeGen is only needed when adding/removing files (`xcodegen generate`).

## Build and test

```sh
cd ios
xcodebuild -project Aisle.xcodeproj -scheme Aisle -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Aisle.xcodeproj -scheme Aisle \
  -destination 'platform=iOS Simulator,name=<your simulator>' test
```

## API base URL

Defaults to `http://127.0.0.1:8000`. Override with, in priority order:

1. `AISLE_API_BASE_URL` environment variable (e.g. in the Xcode scheme's Run options).
2. `AISLE_API_BASE_URL` build setting (`xcodebuild ... AISLE_API_BASE_URL=http://host:port`),
   which is written to `AisleAPIBaseURL` in Info.plist.

Plain HTTP is allowed only for local networking (`NSAllowsLocalNetworking`).

## Layout

- `Aisle/App` – app entry, tab root, `/health` monitor
- `Aisle/Config` – `AppConfig` (base URL resolution)
- `Aisle/Networking` – `APIClient` / `AisleAPI` protocol
- `Aisle/Models` – `Store`, `HealthResponse`
- `Aisle/Location` – optional CoreLocation wrapper
- `Aisle/Stores` – persisted store selection, store picker model
- `Aisle/Features` – Find (current store + picker), List and You placeholders
