cask "macscreen" do
  version "0.1.0-beta.2"
  sha256 "afc3213cb531e7a57e7909b99254dc3f8e00cc7831a71c6c9f6038850c5c25c0"

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
