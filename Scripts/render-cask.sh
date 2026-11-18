#!/usr/bin/env bash
# Writes Casks/macscreen.rb for a release. Called by the release workflow after the DMG is published.
# Usage: Scripts/render-cask.sh <version-without-v> <sha256-of-dmg>
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
VERSION="${1:?usage: render-cask.sh <version> <sha256>}"
SHA="${2:?usage: render-cask.sh <version> <sha256>}"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "Not a sha256: $SHA" >&2; exit 1; }

mkdir -p Casks
cat > Casks/macscreen.rb <<R
cask "macscreen" do
  version "${VERSION}"
  sha256 "${SHA}"

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
R
echo "Wrote Casks/macscreen.rb for ${VERSION}"
