# Building this fork

This fork carries a few changes on top of [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) on branch `bink/transcribe-api`:

- `POST /v1/transcribe` accepts `raw`, `words` and `segments` query options and returns `503` while the model is busy dictating.
  `raw=1` returns the model's own output: no vocabulary boosting, no pronunciation corrections (dictionary voice profiles), no filler-word removal and no custom-dictionary replacements. Word timings therefore always line up with the text, also when dictation uses corrections.
- The local API only answers requests whose `Host` header is `127.0.0.1`, `localhost` or `[::1]` (with or without the port). Anything else gets `403`, so web pages cannot reach the API through DNS rebinding.

## Build and run

```sh
xcodebuild -project Fluid.xcodeproj -scheme Fluid -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
osascript -e 'quit app "FluidVoice"'; osascript -e 'quit app "FluidVoice Debug"'
open "build/Build/Products/Debug/FluidVoice Debug.app"
```

The debug app has its own bundle id, `com.FluidApp.app.debug`, and therefore its own settings. Enable the local API once (with the app closed) and pick Parakeet TDT v3 in its settings:

```sh
defaults write com.FluidApp.app.debug LocalAPIEnabled -bool true
```

An unsigned build may lose microphone and accessibility permissions; grant them again when macOS asks. Run only one FluidVoice at a time, since both use port 47733.

## Check

```sh
curl -s http://127.0.0.1:47733/v1/health                                  # 200
curl -s -H 'Host: evil.example:47733' http://127.0.0.1:47733/v1/health    # 403
Tests/run_local_api_host_policy_tests.sh
```

## Updating from upstream

```sh
git fetch origin
git rebase origin/main bink/transcribe-api
git push --force-with-lease fork bink/transcribe-api
```

`origin` is upstream; `fork` is this repository.
