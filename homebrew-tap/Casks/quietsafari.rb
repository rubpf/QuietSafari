cask "quietsafari" do
  version "0.3.0"
  # Replace :no_check with the QuietSafari.zip digest from SHA256SUMS.txt
  # on the matching GitHub release once that release exists.
  sha256 :no_check

  url "https://github.com/rubpf/QuietSafari/releases/download/v#{version}/QuietSafari.zip"
  name "QuietSafari"
  desc "Quiet ad blocker for Safari on Mac"
  homepage "https://rubpf.github.io/QuietSafari/"

  depends_on macos: ">= :sonoma"

  app "QuietSafari.app"

  caveats <<~EOS
    This build is ad-hoc signed. macOS will quarantine it.

    Install without quarantine:

      brew install --cask --no-quarantine rubpf/tap/quietsafari

    Or clear it afterwards:

      xattr -dr com.apple.quarantine "#{appdir}/QuietSafari.app"

    Safari also needs Develop → Allow Unsigned Extensions, and the four QuietSafari checkboxes.
    Allow Unsigned Extensions turns off every time Safari quits.
  EOS

  zap trash: [
    "~/Library/Application Support/QuietSafari",
    "~/Library/Containers/com.quietsafari.macos",
  ]
end
