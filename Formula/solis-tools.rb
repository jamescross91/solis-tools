class SolisTools < Formula
  include Language::Python::Virtualenv

  desc "Nmon-inspired terminal monitor for Solis hybrid inverters"
  homepage "https://github.com/jamescross91/solis-tools"
  url "https://github.com/jamescross91/solis-tools/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "58368e4e0c6ca944442da7d552ed2037e791977cd568894901bdc8401ff061d7"
  license "GPL-3.0-only"

  depends_on "python@3.14"

  resource "pymodbus" do
    url "https://files.pythonhosted.org/packages/e5/b8/03dace16e0e5d1c3eb16e8b9bcce9885f5e8a38db34345ec375cd70ed2e2/pymodbus-3.15.0.tar.gz"
    sha256 "4c5f715128bfeba59f4c9fb3542b0c32a8afd4b90081111e39c12f7af0c89aae"
  end

  def install
    virtualenv_install_with_resources
  end

  test do
    assert_match "solis-poll #{version}", shell_output("#{bin}/solis-poll --version")
    assert_match "--host HOST", shell_output("#{bin}/solis-poll --help")
  end
end
