class SolisTools < Formula
  include Language::Python::Virtualenv

  desc "Nmon-inspired terminal monitor for Solis hybrid inverters"
  homepage "https://github.com/jamescross91/solis-tools"
  url "https://github.com/jamescross91/solis-tools/releases/download/v0.5.3/solis-tools-0.5.3.tar.gz"
  sha256 "433390ac21d604161c26ce6284eb89a93b7f3fa94a01e62b2915ec68749811bc"
  license "GPL-3.0-only"

  # `brew install --HEAD solis-tools` builds the current main branch, so a change
  # can be tried before it is tagged and released.
  head "https://github.com/jamescross91/solis-tools.git", branch: "main"

  depends_on "python@3.14"

  resource "pymodbus" do
    url "https://files.pythonhosted.org/packages/e5/b8/03dace16e0e5d1c3eb16e8b9bcce9885f5e8a38db34345ec375cd70ed2e2/pymodbus-3.15.0.tar.gz"
    sha256 "4c5f715128bfeba59f4c9fb3542b0c32a8afd4b90081111e39c12f7af0c89aae"
  end

  # BEGIN PREBUILT MACOS
  resource "solis-menubar" do
    on_macos do
      url "https://github.com/jamescross91/solis-tools/releases/download/v0.5.3/solis-menubar-0.5.3-macos-universal.tar.gz"
      sha256 "5c0732a6ddc4b9b35f2def585f2f5da7e76ee1e54dc3a9744f7b4d5e10a26ab7"
    end
  end
  # END PREBUILT MACOS

  def install
    prebuilt = resources.any? { |item| item.name == "solis-menubar" }
    virtualenv_install_with_resources without: (prebuilt ? ["solis-menubar"] : nil)
    return unless OS.mac?

    app = prefix/"SolisMenuBar.app"
    if !build.head? && prebuilt
      resource("solis-menubar").stage { prefix.install "SolisMenuBar.app" }
      system "codesign", "--verify", "--strict", app
    else
      # HEAD and historical source-only releases remain developer builds.
      system "swift", "build", "--disable-sandbox", "--configuration", "release",
             "--package-path", "SolisMenuBar"
      swift_bin = Utils.safe_popen_read(
        "swift", "build", "--disable-sandbox", "--configuration", "release",
        "--package-path", "SolisMenuBar", "--show-bin-path"
      ).strip
      (app/"Contents/MacOS").install Pathname(swift_bin)/"SolisMenuBar"
      (app/"Contents").install "SolisMenuBar/Resources/Info.plist"
      system "codesign", "--force", "--sign", "-", app
    end
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
