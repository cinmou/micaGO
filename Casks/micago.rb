cask "micago" do
  version "0.94.1"
  sha256 "6fce22caac2dddc6c83e121aabf59e77492dbe2fe1bf57731086de9632b1d232"

  url "https://github.com/cinmou/micaGO/releases/download/v#{version}/micaGO-#{version}-Mac.dmg"
  name "micaGO Companion"
  desc "Connects your devices to Messages on your Mac"
  homepage "https://github.com/cinmou/micaGO"

  auto_updates true
  depends_on macos: :ventura

  app "micaGO Companion.app"
end
