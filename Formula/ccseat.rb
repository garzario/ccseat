# Homebrew formula for ccseat. This repository doubles as a tap:
#
#   brew tap garzario/ccseat https://github.com/garzario/ccseat
#   brew install ccseat
class Ccseat < Formula
  desc "Use several Claude Code accounts side by side, one seat per account"
  homepage "https://github.com/garzario/ccseat"
  url "https://github.com/garzario/ccseat/archive/refs/tags/v0.2.2.tar.gz"
  sha256 "c36856f292b040f5861e1d723dc32e5a480539a0f6d15e6c5aaadb888eb9c9ca"
  license "MIT"
  head "https://github.com/garzario/ccseat.git", branch: "main"

  depends_on "jq"

  uses_from_macos "curl"

  def install
    libexec.install "bin", "lib"
    bin.install_symlink libexec/"bin/ccseat"
  end

  def caveats
    <<~EOS
      ccseat needs Claude Code itself (the claude command):
        curl -fsSL https://claude.ai/install.sh | bash

      Then turn on the shell integration, so "claude" opens your current seat
      and switches seats at a limit:
        ccseat setup
      (or add it by hand: eval "$(ccseat init zsh)" in ~/.zshrc, the same with
      bash in ~/.bash_profile, or "ccseat init fish | source" for fish)

      Next steps:
        ccseat add                  add a seat (logs in to another account)
        cc (or ccseat)              pick a seat and open Claude Code
        ccseat statusline install   show the seat and usage under the prompt

      Before brew uninstall ccseat, run: ccseat uninstall
      (it removes the shell integration and puts back your old status line)
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ccseat --version")
    assert_match "claude", shell_output("#{bin}/ccseat init zsh")
  end
end
