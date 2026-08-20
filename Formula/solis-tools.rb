class SolisTools < Formula
  include Language::Python::Virtualenv

  desc "Nmon-inspired terminal monitor for Solis hybrid inverters"
  homepage "https://github.com/jamescross91/solis-tools"
  url "https://github.com/jamescross91/solis-tools/releases/download/v0.4.0/solis-tools-0.4.0.tar.gz"
  sha256 "c1bc215c105497f00af511c1164c8532863dd17ec4e4e1cd9b0ca1afaa3e16e0"
  license "GPL-3.0-only"

  # `brew install --HEAD solis-tools` builds the current main branch, so a change
  # can be tried before it is tagged and released.
  head "https://github.com/jamescross91/solis-tools.git", branch: "main"

  depends_on "python@3.14"

  resource "pymodbus" do
    url "https://files.pythonhosted.org/packages/e5/b8/03dace16e0e5d1c3eb16e8b9bcce9885f5e8a38db34345ec375cd70ed2e2/pymodbus-3.15.0.tar.gz"
    sha256 "4c5f715128bfeba59f4c9fb3542b0c32a8afd4b90081111e39c12f7af0c89aae"
  end

  def install
    virtualenv_install_with_resources
    return unless OS.mac?

    system "swift", "build", "--disable-sandbox", "--configuration", "release",
           "--package-path", "SolisMenuBar"
    swift_bin = Utils.safe_popen_read(
      "swift", "build", "--disable-sandbox", "--configuration", "release",
      "--package-path", "SolisMenuBar", "--show-bin-path"
    ).strip
    app = prefix/"SolisMenuBar.app"
    (app/"Contents/MacOS").install Pathname(swift_bin)/"SolisMenuBar"
    (app/"Contents").install "SolisMenuBar/Resources/Info.plist"
    system "codesign", "--force", "--sign", "-", app
    (bin/"solis-menubar").write <<~SH
      #!/bin/bash
      if [[ "$1" == "--version" ]]; then
        exec "#{app}/Contents/MacOS/SolisMenuBar" --version
      fi
      exec /usr/bin/open "#{app}"
    SH
    (bin/"solis-menubar").chmod 0755
  end

  test do
    # `version` is the literal string "HEAD" for a --HEAD install; the actual
    # reported version there tracks solis_poll.VERSION on that branch, which
    # this test cannot know in advance, so it checks the shape instead.
    version_pattern = build.head? ? /\d+\.\d+\.\d+/ : /#{Regexp.escape(version.to_s)}/
    assert_match(/solis-poll #{version_pattern}/, shell_output("#{bin}/solis-poll --version"))
    assert_match "--host HOST", shell_output("#{bin}/solis-poll --help")
    return unless OS.mac?

    assert_path_exists prefix/"SolisMenuBar.app/Contents/Info.plist"
    assert_match(/solis-menubar #{version_pattern}/,
                 shell_output("#{bin}/solis-menubar --version"))
  end
end
