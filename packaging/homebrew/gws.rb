class Gws < Formula
  desc "Persistent Ghostty workspaces on top of zmx"
  homepage "https://github.com/en9inerd/gws"
  license "MIT"
  version "VERSION_PLACEHOLDER"

  depends_on :macos
  depends_on "fzf"
  depends_on "neurosnap/tap/zmx"

  on_macos do
    on_arm do
      url "https://github.com/en9inerd/gws/releases/download/vVERSION_PLACEHOLDER/gws_aarch64-macos.tar.gz"
      sha256 "SHA256_MACOS_ARM64"
    end
    on_intel do
      url "https://github.com/en9inerd/gws/releases/download/vVERSION_PLACEHOLDER/gws_x86_64-macos.tar.gz"
      sha256 "SHA256_MACOS_AMD64"
    end
  end

  def install
    bin.install "gws"
  end

  test do
    assert_match "gws #{version}", shell_output("#{bin}/gws --version")
  end
end
