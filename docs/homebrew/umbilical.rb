# Draft for ks1686/homebrew-tap.
# The release workflow uploads the same cask with the real version and sha256.
# Do not push this file. Copy the release asset into the tap after review.
cask "umbilical" do
  version "0.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ks1686/umbilical/releases/download/v#{version}/umbilical-#{version}.dmg"
  name "umbilical"
  desc "Download manager that never seeds"
  homepage "https://github.com/ks1686/umbilical"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "umbilical.app"

  zap trash: [
    "~/Library/Caches/me.peapod.umbilical",
    "~/Library/Containers/me.peapod.umbilical.extension",
    "~/Library/HTTPStorages/me.peapod.umbilical",
    "~/Library/Preferences/me.peapod.umbilical.extension.plist",
    "~/Library/Preferences/me.peapod.umbilical.plist",
    "~/Library/Saved Application State/me.peapod.umbilical.savedState",
    "~/Library/WebKit/me.peapod.umbilical",
  ]
end
