class Gws < Formula
  desc "Persistent Ghostty workspaces on top of zmx"
  homepage "https://github.com/en9inerd/gws"
  license "MIT"
  version "VERSION_PLACEHOLDER"

  depends_on arch: :arm64
  depends_on :macos
  depends_on "fzf"

  on_macos do
    url "https://github.com/en9inerd/gws/releases/download/vVERSION_PLACEHOLDER/gws_aarch64-macos.tar.gz"
    sha256 "SHA256_MACOS_ARM64"
  end

  def install
    bin.install "gws"
  end

  test do
    assert_match "gws #{version}", shell_output("#{bin}/gws --version")
  end
end
