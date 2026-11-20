cask "macscreen" do
  version "0.1.0-beta.4"
  sha256 "d33921e7ad77a2ddfad9159232eddfa4004b516e3488bb0cf26af8a890559596"

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
