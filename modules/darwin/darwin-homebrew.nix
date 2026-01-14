{ lib, config, ... }:

{
  options = {
    smind.darwin.brew.enable = lib.mkEnableOption "Homebrew package management";
  };

  config = {
    homebrew = lib.mkIf config.smind.darwin.brew.enable {
      enable = true;
      onActivation.autoUpdate = true;
      onActivation.upgrade = true;
      onActivation.cleanup = "zap";
      caskArgs.no_quarantine = true;
      taps = [
        #"homebrew/cask-fonts" # dead
      ];

      brews = [
        # "radare2"
        # "qt@5"
        # "nasm"
        # "bochs"
        # "pandoc"
      ];

      casks = map (name: { name = name; greedy = true; }) [
        "firefox"
        "librewolf"
        "tor-browser"
        "brave-browser"

        "anytype"

        "android-platform-tools"
        "adobe-acrobat-reader"
        "alfred"
        "android-platform-tools"
        "appcleaner"

        "rancher"
        "element"
        "nheko"
        "session"

        "font-fira-code-nerd-font"
        "font-fira-mono-nerd-font"
        "font-fira-sans"
        "ghidra"
        "iterm2"
        "jetbrains-toolbox"
        # "jprofiler"
        "megasync"
        "microsoft-remote-desktop"
        "nordvpn"
        "rectangle"
        # "skype"
        # "steam"
        "sublime-merge"
        "imhex"
        "wireshark-app"
        "tailscale-app"
        #"the-unarchiver"
        "keka"
        "crystalfetch"
        "ibkr"
        "trader-workstation"
        # "horos"
        "wine-stable"
        # "fman"
        "far2l"
        "linearmouse"
        "tunnelblick"
        "ungoogled-chromium"

        # hm version works with full disk access annoyances
        "wezterm"
        "vscodium"

        # hm version works
        "iina"
        "qbittorrent"
        "slack"
        "discord"

        # hm version works as cli command but not as app
        "cutter"

        "home-assistant"

        "vmware-fusion"
        "86box"

        "wifiman"

        "ledger-live"
        "trezor-suite"
        "gzdoom"

        "winbox"

        "mqttx"

        # don't need for now
        # "dotnet-sdk"

        # "utm"
        # "protonvpn"
        # "dosbox-x" # SDL1 build, can't maximize
        # "zerotier-one"
        # "transmission"
        #"teamviewer"
      ];
      masApps = {
        "Audio Profile Manager" = 1484150558;
        "Bitwarden Password Manager" = 1352778147;
        "CotEditor" = 1024640650;
        "EasyRes" = 688211836;
        "Shareful" = 1522267256;
        # mas can't handle iPad apps https://github.com/mas-cli/mas/issues/321
        # "UniFi Protect" = 1392492235; # https://apps.apple.com/us/app/unifi-protect/id1392492235
      };
    };
  };
}
