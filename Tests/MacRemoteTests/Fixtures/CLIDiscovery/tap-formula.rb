class Apfs < Formula
  desc "APFS parser written in pure Go"
  homepage "https://github.com/blacktop/go-apfs"
  url "https://github.com/blacktop/go-apfs/releases/download/v1.0.28/go-apfs_1.0.28_macOS_arm64.tar.gz"
  sha256 "redacted"

  def install
    bin.install "apfs"
  end
end
