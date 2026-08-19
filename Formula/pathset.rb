# The `url` and `sha256` below are rewritten by `make formula VERSION=X.Y.Z`
# after the tag is pushed; don't edit them by hand.
#
# To test without a tap: brew install --build-from-source ./Formula/pathset.rb

class Pathset < Formula
  desc "Tiny C utility that turns a directory list into a PATH value"
  homepage "https://github.com/grazij/pathset"
  url "https://github.com/grazij/pathset/archive/refs/tags/v0.3.2.tar.gz"
  sha256 "ed415674df012a5f695e8b67a31845d2b0bfcf7a95bf061e8797799c7b676b3e"
  license "MIT"
  head "https://github.com/grazij/pathset.git", branch: "main"

  def install
    # Plain `build`: no help2man (pathset.1 ships pre-generated in the
    # tarball) and no test run — correctness is settled by `make release`
    # before tagging, not on the installer's machine.
    system "make", "build", "VERSION=#{version}"
    bin.install "pathset"
    man1.install "pathset.1"
    pkgshare.install "examples"
  end

  test do
    cfg = testpath/"config"
    cfg.write <<~EOS
      #{testpath}
      /nonexistent/dir
    EOS

    # Bare colon-joined output, exit 3 because /nonexistent/dir is skipped.
    output = shell_output("#{bin}/pathset -c #{cfg} -q", 3)
    assert_equal testpath.to_s, output.strip

    # -V prints version.
    assert_match version.to_s, shell_output("#{bin}/pathset -V")
  end
end
