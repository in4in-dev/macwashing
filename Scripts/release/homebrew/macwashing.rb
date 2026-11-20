# A template of a Homebrew cask for MacWashing; nothing updates it by itself. To submit it to homebrew/cask, set
# `version` and `sha256` of the latest release (publish-release.sh prints the sha256 of the DMG).
cask "macwashing" do
  version "1.0"
  sha256 :no_check

  url "https://github.com/in4in-dev/macwashing/releases/download/v#{version}/MacWashing-#{version}.dmg"
  name "MacWashing"
  desc "Disk cleaner and app uninstaller"
  homepage "https://github.com/in4in-dev/macwashing"

  livecheck do
    url "https://raw.githubusercontent.com/in4in-dev/macwashing/main/updates/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "MacWashing.app"

  uninstall launchctl: "com.ovvi.MacWashing.Helper",
            quit:      "com.ovvi.MacWashing"

  zap trash: [
    "~/Library/Application Support/com.ovvi.MacWashing",
    "~/Library/Caches/com.ovvi.MacWashing",
    "~/Library/HTTPStorages/com.ovvi.MacWashing",
    "~/Library/Preferences/com.ovvi.MacWashing.plist",
    "~/Library/Saved Application State/com.ovvi.MacWashing.savedState",
    "~/Library/WebKit/com.ovvi.MacWashing",
  ]
end
