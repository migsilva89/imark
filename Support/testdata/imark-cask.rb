cask "imark" do
  version "0.4.0"
  sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  url "https://github.com/migsilva89/imark/releases/download/v#{version}/Imark-#{version}.dmg"
  name "Imark"
  desc "Review Markdown with comments"
  homepage "https://imarkmd.com"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Imark.app"

  zap trash: "~/Library/Preferences/pt.miguelsilva.imark.plist"
end
