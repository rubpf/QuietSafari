# rubpf/homebrew-tap

This folder is the cask to copy into a public repository named `homebrew-tap` under the GitHub user `rubpf`. Homebrew then serves it as `rubpf/tap`.

## One-time setup

1. Create an empty public repository `rubpf/homebrew-tap`.
2. Put `Casks/quietsafari.rb` at the root of that repository (the same path as here).
3. After the first QuietSafari release exists, open `SHA256SUMS.txt` on the release and replace `sha256 :no_check` with:

```ruby
sha256 "<the QuietSafari.zip digest>"
```

The `version` line must match the tag without the leading `v`. The app’s current version is `0.3.0`, so the tag is `v0.3.0`.

## Install

```bash
brew tap rubpf/tap
brew install --cask --no-quarantine rubpf/tap/quietsafari
```

`--no-quarantine` skips the Gatekeeper block on an ad-hoc signature. Without that flag, run:

```bash
xattr -dr com.apple.quarantine /Applications/QuietSafari.app
```

Then open the app and follow the Russian onboarding: Allow Unsigned Extensions, and enable all four QuietSafari extensions.
