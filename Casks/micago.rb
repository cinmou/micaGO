cask "micago" do
  version "0.96.0"
  sha256 "f1a4505d155a6d7ff855283bdc98916fb7d51e114122842d7731aae01bb102ac"

  url "https://github.com/cinmou/micaGO/releases/download/v#{version}/micaGO-#{version}-Mac.dmg"
  name "micaGO Companion"
  desc "Connects your devices to Messages on your Mac"
  homepage "https://github.com/cinmou/micaGO"

  auto_updates true
  depends_on macos: :ventura

  app "micaGO Companion.app"
end
