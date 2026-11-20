cask "macscreen" do
  version "0.1.0-beta.5"
  sha256 "836dd5e07dd41e92dfc15e287257cc76eb42acfdb3960d2bd0dde2b973fe1f0c"

  url "https://github.com/danyk20/MacScreen/releases/download/v#{version}/MacScreen-v#{version}.dmg"
  name "MacScreen"
  desc "Extend your screen onto a second computer"
  homepage "https://danyk20.github.io/MacScreen/"

  depends_on macos: :monterey

  app "MacScreen.app"

  # The app is not notarized by Apple, so clear the download quarantine flag to let it open normally.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/MacScreen.app"]
  end

  zap trash: "~/Library/Preferences/app.macscreen.MacScreen.plist"
end
