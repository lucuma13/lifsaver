cask "lifsaver" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/lucuma13/lifsaver/releases/download/v#{version}/lifsaver-#{version}-macos-universal.zip"
  name "lifsaver"
  desc "Force-mount external camera cards stuck in macOS LIFS Disk Utility limbo"
  homepage "https://github.com/lucuma13/lifsaver"

  app "Lifsaver.app"
  binary "#{appdir}/Lifsaver.app/Contents/Helpers/lifsaver", target: "lifsaver"

  postflight do
    if OS.mac? && File.exist?("#{appdir}/Lifsaver.app")
      system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Lifsaver.app"]
    end
  end

  zap trash: [
    "~/Library/Caches/lifsaver",
  ]
end
