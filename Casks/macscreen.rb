cask "macscreen" do
  version "0.1.0-beta.3"
  sha256 "42e1f4a177c5f57212767a501576fbbcaa52e1741bb45a4460473a5e702a6477"

  url "https://github.com/danyk20/MacScreen/releases/download/v#{version}/MacScreen-v#{version}.dmg"
  name "MacScreen"
  desc "Extend your screen onto a second computer"
  homepage "https://github.com/danyk20/MacScreen"

  depends_on macos: :monterey

  app "MacScreen.app"

  # The app is not notarized by Apple, so clear the download quarantine flag to let it open normally.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/MacScreen.app"]
  end

  zap trash: "~/Library/Preferences/app.macscreen.MacScreen.plist"
end
