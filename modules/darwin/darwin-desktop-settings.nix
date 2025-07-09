{ pkgs, lib, config, ... }:

{
  options = {
    smind.darwin.sysconfig.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.darwin.sysconfig.enable {
    #alf = { globalstate = 1; };
    networking.applicationFirewall = {
      enable = false;
      blockAllIncoming = false;
    };
    system.defaults = {
      CustomSystemPreferences = {
        "/Library/Preferences/com.apple.SoftwareUpdate.plist" = {
          "AutomaticDownload" = true;
        };
      };
      CustomUserPreferences = {
        "NSGlobalDomain" = {
          "TISRomanSwitchState" = 1; # "Use CapsLock for input source switching"
          "AppleHighlightColor" =
            "0.847059 0.847059 0.862745 Graphite"; # "Graphite/Gray accent/Highlight"
          "NSNavPanelExpandedStateForSaveMode" = true;
          "com.apple.mouse.tapBehavior" = 1;
          # "com.apple.mouse.tapBehavior" = 1; # currenthost!
          "NSAutomaticTextCompletionEnabled" = false;
          "WebKitDeveloperExtras" =
            true; # "Adding a context menu item for showing the Web Inspector in web views"
          "com.apple.mouse.scaling" = 2.5;
          userMenuExtraStyle = 2;

          # decrease padding between menu bar items
          NSStatusItemSpacing = 6;
          NSStatusItemSelectionPadding = 6;
        };

        "com.apple.TextInputMenu" = { visible = true; };

        "com.apple.Safari" = {
          "com.apple.Safari.ContentPageGroupIdentifier.WebKit2DeveloperExtrasEnabled" =
            true;
          IncludeInternalDebugMenu = true;
          IncludeDevelopMenu = true;
          WebKitDeveloperExtrasEnabledPreferenceKey = true;
          AutoFillCreditCardData = 0;
          AutoFillFromAddressBook = 0;
          AutoFillMiscellaneousForms = 0;
          AutoFillPasswords = 0;
        };

        "com.apple.AdLib" = {
          forceLimitAdTracking = true;
          allowApplePersonalizedAdvertising = false;
          allowIdentifierForAdvertising = false;
        };
        "com.apple.AdPlatforms" = {
          AppStorePAAvailable = 0;
          LatestPAVersion = 0;
        };
        "com.apple.SoftwareUpdate" = { "ScheduleFrequency" = 1; };

        "com.apple.BezelServices" = {
          kDim = false;
          kDimTime = 5;
        };

        "com.apple.finder" = {
          NewWindowTarget =
            "PfHm"; # "Show the home folder instead of all files when opening a new finder window"
          _FXSortFoldersFirst = true;
          QLEnableTextSelection =
            true; # "Allowing text selection in Quick Look/Preview in Finder by default"
          FXPreferredSearchViewStyle =
            "Nlsv"; # "Four-letter codes for the other view modes: `icnv`, `clmv`, `Flwv`"
          # ShowExternalHardDrivesOnDesktop = true;
          # ShowRemovableMediaOnDesktop = true;
          # ShowPathBar = true;
          # ShowTabView = true;
        };

        "com.apple.dock" = {
          "scroll-to-open" =
            true; # "While hovering over top of an icon in the Dock, use the scroll wheel on the mouse, or use the scroll gesture on the track pad to expose all the windows in the app"
        };

        # "com.apple.menuextra.battery" = {
        #   ShowPercent = true; # "Show Percent Battery in menu bar"
        # };

        "com.apple.TimeMachine" = {
          DoNotOfferNewDisksForBackup =
            true; # "Prevent Time Machine from Prompting to Use New Hard Drives as Backup Volume"
        };

        "com.apple.Accessibility" = {
          "ReduceMotionEnabled" = 1;
        };

        "com.apple.loginwindow" = {
          "TALLogoutSavesState" = false;
        }; # "Don't reopen apps after restart"

        "com.apple.TextEdit" = {
          RichText = 0;
          ShowRuler = 0;
          IgnoreHTML =
            true; # "Display HTML files as HTML code instead of formatted text in TextEdit"
        };

        "com.apple.iCal" = {
          "first day of week" = 1;
          "TimeZone support enabled" = true;
          "Show heat map in Year View" = true;
        };

        "com.apple.controlcenter" = {
          "NSStatusItem Visible Battery" = 1;
          "NSStatusItem Visible BentoBox" = 1;
          "NSStatusItem Visible Bluetooth" = 1;
          "NSStatusItem Visible Clock" = 1;
          "NSStatusItem Visible Sound" = 1;
          "NSStatusItem Visible UserSwitcher" = 1;
          "NSStatusItem Visible WiFi" = 1;
        };

        # need sudo
        # "/Library/Preferences/com.apple.SoftwareUpdate.plist" = {
        #   "AutomaticDownload" = true;
        # };
        # "com.apple.ImageCapture" = { disableHotPlug = true; }; # currentHost
      };

      NSGlobalDomain = {
        AppleKeyboardUIMode = 3;
        ApplePressAndHoldEnabled = false;
        AppleMeasurementUnits = "Centimeters";
        AppleMetricUnits = 1;
        AppleShowAllExtensions = true;
        AppleShowAllFiles = true;
        AppleShowScrollBars = "Always";
        AppleTemperatureUnit = "Celsius";
        InitialKeyRepeat = 25;
        KeyRepeat = 2;
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticQuoteSubstitutionEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        NSAutomaticDashSubstitutionEnabled = false;
        NSAutomaticPeriodSubstitutionEnabled = false;

        NSAutomaticWindowAnimationsEnabled = false;
        NSNavPanelExpandedStateForSaveMode = true;
        NSNavPanelExpandedStateForSaveMode2 = true;
        PMPrintingExpandedStateForPrint = true;
        PMPrintingExpandedStateForPrint2 = true;

        NSTextShowsControlCharacters = true;
        NSDocumentSaveNewDocumentsToCloud = false;
        "com.apple.keyboard.fnState" = true;
      };

      LaunchServices = { LSQuarantine = false; };

      dock = {
        autohide = true;
        autohide-delay = 0.0;
        autohide-time-modifier = 0.0;
        mineffect = "scale";
        minimize-to-application = true;
        expose-animation-duration = 0.0;
        orientation = "bottom";
        show-recents = false;
        mru-spaces = false;
        showhidden = true;
        expose-group-apps = true;
        show-process-indicators = true;
      };
      finder = {
        AppleShowAllExtensions = true;
        AppleShowAllFiles = true;
        FXDefaultSearchScope = "SCcf";
        FXEnableExtensionChangeWarning = false;
        FXPreferredViewStyle = "Nlsv";
        QuitMenuItem = true;
        ShowStatusBar = true;
      };

      ActivityMonitor = { ShowCategory = 100; };

      trackpad = {
        Clicking = true;
      };

      loginwindow = {
        LoginwindowText =
          "This Mac is a property of Septimal Mind Ltd. Please email team@7mind.io if you found it.";
      };
    };

    # fonts = {
    #   #  fontDir.enable = true;
    #   packages = with pkgs;
    #     [
    #       (nerdfonts.override {
    #         fonts = [
    #           "DroidSansMono"
    #           "FiraCode"
    #           "Hack"
    #           "Iosevka"
    #           "FiraMono"
    #           "JetBrainsMono"
    #           "RobotoMono"
    #           "Meslo"
    #         ];
    #       })
    #     ];
    # };

    fonts = {
      packages = (with pkgs.nerd-fonts;
        [
          droid-sans-mono
          fira-code
          hack
          iosevka
          fira-mono
          jetbrains-mono
          roboto-mono
          inconsolata
          meslo-lg
          ubuntu-mono
          dejavu-sans-mono
        ]);
    };
  };
}
