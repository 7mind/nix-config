{ config, lib, pkgs, xdg_associate, cfg-meta, ... }:

{
  options = {
    smind.hm.firefox.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Firefox with custom configuration and extensions";
    };
    smind.hm.firefox.sync-username = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Firefox Sync account username";
    };
  };

  config = lib.mkIf config.smind.hm.firefox.enable {
    programs.firefox = {
      package = lib.mkIf cfg-meta.isDarwin null;
      enable = true;
      # https://github.com/mozilla/policy-templates/blob/master/linux/policies.json
      policies = {
        "DisableFirefoxStudies" = true;
        "DisablePocket" = true;
        "DisableTelemetry" = true;
        "FirefoxHome" = {
          "Search" = false;
          "TopSites" = false;
          "SponsoredTopSites" = false;
          "Highlights" = false;
          "Pocket" = false;
          "SponsoredPocket" = false;
          "Snippets" = false;
          "Locked" = false;
        };

        "ExtensionSettings" = {
          "uBlock0@raymondhill.net" = {
            "installation_mode" = "force_installed";
            "install_url" = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
          };
          "{3c078156-979c-498b-8990-85f7987dd929}" = {
            "installation_mode" = "force_installed";
            "install_url" = "https://addons.mozilla.org/firefox/downloads/latest/sidebery/latest.xpi";
          };
        };
      };

      profiles = {
        main = {
          name = "main";
          isDefault = true;
          settings = {
            "services.sync.username" = lib.mkIf (config.smind.hm.firefox.sync-username != "") config.smind.hm.firefox.sync-username;

            "browser.startup.homepage" = "about:home";
            "browser.startup.page" = 3; # Restore previous session

            "browser.toolbars.bookmarks.visibility" = "newtab";
            "browser.search.update" = false;
            "browser.shell.checkDefaultBrowser" = false;
            "browser.newtabpage.enabled" = true;
            "browser.newtabpage.pinned" = builtins.toJSON [ ];

            "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons" =
              false;
            "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features" =
              false;
            "browser.newtabpage.activity-stream.feeds.section.highlights" = false;
            "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
            "browser.newtabpage.activity-stream.feeds.snippets" = false;
            "browser.newtabpage.activity-stream.feeds.telemetry" = false;
            "browser.newtabpage.activity-stream.feeds.topsites" = true;
            "browser.newtabpage.activity-stream.improvesearch.topSiteSearchShortcuts.havePinned" =
              "google"; # Don't autopin google on first run
            "browser.newtabpage.activity-stream.section.highlights.includePocket" =
              false;
            "browser.newtabpage.activity-stream.showSponsored" = false;
            "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
            "browser.newtabpage.activity-stream.telemetry" = false;
            "browser.newtabpage.blocked" = builtins.toJSON {
              # Dismiss builtin shortcuts
              "26UbzFJ7qT9/4DhodHKA1Q==" = 1;
              "4gPpjkxgZzXPVtuEoAL9Ig==" = 1;
              "eV8/WsSLxHadrTL1gAxhug==" = 1;
              "gLv0ja2RYVgxKdp0I5qwvA==" = 1;
              "oYry01JR5qiqP3ru9Hdmtg==" = 1;
              "T9nJot5PurhJSy8n038xGA==" = 1;
            };

            "app.shield.optoutstudies.enabled" = false;
            "browser.aboutConfig.showWarning" = false;
            "browser.aboutwelcome.enabled" = false;
            "browser.contentblocking.category" = "strict";
            "browser.discovery.enabled" = false;
            "browser.link.open_newwindow.restriction" = 0;
            "datareporting.healthreport.uploadEnabled" = false;
            "datareporting.policy.dataSubmissionEnabled" = false;
            "devtools.netmonitor.persistlog" = true;
            "devtools.selfxss.count" = 5; # Allow pasting into console
            "devtools.theme" = "dark";
            # FirefoxSync breaks when Push notifications are disabled
            #
            # "dom.push.enabled" = false;
            # "dom.pushconnection.enabled" = false;
            # "dom.webnotifications.enabled" = false;
            # "dom.webnotifications.serviceworker.enabled" = false;
            #
            "dom.push.enabled" = true;
            "dom.pushconnection.enabled" = true;
            "dom.webnotifications.enabled" = true;
            "dom.webnotifications.serviceworker.enabled" = true;
            #
            "extensions.formautofill.creditCards.available" = false;
            "extensions.formautofill.creditCards.enabled" = false;
            "security.enterprise_roots.enabled" = true;
            "security.sandbox.content.level" = 3;
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

            "widget.use-xdg-desktop-portal.file-picker" = 1;
            "widget.use-xdg-desktop-portal.mime-handler" = 1;
            "widget.use-xdg-desktop-portal.location" = 1;
            "widget.use-xdg-desktop-portal.settings" = 1;
            "widget.use-xdg-desktop-portal.open-uri" = 1;

            #"gfx.webrender.all" = true;
            #"gfx.webrender.compositor" = true;
            #browser.uiCustomization.state" = builtins.toJSON { };

            # betterfox / fastfox
            "browser.cache.memory.max_entry_size" = 153600;
            "browser.startup.preXulSkeletonUI" = false;
            "content.notify.interval" = 100000;
            "dom.enable_web_task_scheduling" = true;
            "gfx.canvas.accelerated" = true;
            "gfx.canvas.accelerated.cache-items" = 32768;
            "gfx.canvas.accelerated.cache-size" = 4096;
            "gfx.content.skia-font-cache-size" = 80;
            "gfx.webrender.all" = true;
            "gfx.webrender.compositor" = true;
            "gfx.webrender.precache-shaders" = true;
            "image.cache.size" = 10485760;
            "image.mem.decode_bytes_at_a_time" = 131072;
            "image.mem.shared.unmap.min_expiration_ms" = 120000;
            "layers.gpu-process.enabled" = true;
            "layout.css.grid-template-masonry-value.enabled" = true;
            "media.cache_readahead_limit" = 9000;
            "media.cache_resume_threshold" = 6000;
            "media.hardware-video-decoding.enabled" = true;
            "media.memory_cache_max_size" = 1048576;
            "media.memory_caches_combined_limit_kb" = 2560000;
            "network.buffer.cache.count" = 128;
            "network.buffer.cache.size" = 262144;
            "network.http.max-connections" = 1800;
            "network.http.max-persistent-connections-per-server" = 10;
            "network.ssl_tokens_cache_capacity" = 32768;
            "nglayout.initialpaint.delay" = 0;
            "nglayout.initialpaint.delay_in_oopif" = 0;

            # betterfox / smoothfox opt 3
            "general.smoothScroll" = true;
            "general.smoothScroll.msdPhysics.continuousMotionMaxDeltaMS" = 12;
            "general.smoothScroll.msdPhysics.enabled" = true;
            "general.smoothScroll.msdPhysics.motionBeginSpringConstant" = 600;
            "general.smoothScroll.msdPhysics.regularSpringConstant" = 650;
            "general.smoothScroll.msdPhysics.slowdownMinDeltaMS" = 25;
            "general.smoothScroll.msdPhysics.slowdownMinDeltaRatio" = 2.0;
            "general.smoothScroll.msdPhysics.slowdownSpringConstant" = 250;
            "general.smoothScroll.currentVelocityWeighting" = 1.0;
            "general.smoothScroll.stopDecelerationWeighting" = 1.0;
            "mousewheel.default.delta_multiplier_y" = 300;
            #
            "browser.compactmode.show" = true;

            # betterfox / securefox
            "accessibility.force_disabled" = 1;
            "app.normandy.api_url" = "";
            "app.normandy.enabled" = false;
            "breakpad.reportURL" = "";
            "browser.crashReports.unsubmittedCheck.autoSubmit2" = false;
            "browser.ping-centre.telemetry" = false;
            "browser.places.speculativeConnect.enabled" = false;
            "browser.tabs.crashReporting.sendReport" = false;
            "browser.tabs.firefox-view" = false;
            "browser.uitour.enabled" = false;
            "browser.urlbar.speculativeConnect.enabled" = false;
            "browser.xul.error_pages.expert_bad_cert" = true;
            "captivedetect.canonicalURL" = "";
            "default-browser-agent.enabled" = false;
            "dom.security.https_first" = true;
            "geo.provider.ms-windows-location" = false;
            "geo.provider.use_corelocation" = false;
            "geo.provider.use_geoclue" = false;
            "geo.provider.use_gpsd" = false;
            "network.IDN_show_punycode" = true;
            "network.captive-portal-service.enabled" = false;
            "network.connectivity-service.enabled" = false;
            "network.dns.disablePrefetch" = true;
            "network.http.speculative-parallel-limit" = 0;
            "network.predictor.enable-prefetch" = false;
            "network.predictor.enabled" = false;
            "network.prefetch-next" = false;
            "pdfjs.enableScripting" = false;
            "permissions.default.desktop-notification" = 2;
            "permissions.default.geo" = 2;
            "privacy.globalprivacycontrol.enabled" = true;
            "privacy.globalprivacycontrol.functionality.enabled" = true;
            "privacy.query_stripping.strip_list" =
              "__hsfp __hssc __hstc __s _hsenc _openstat dclid fbclid gbraid gclid hsCtaTracking igshid mc_eid ml_subscriber ml_subscriber_hash msclkid oft_c oft_ck oft_d oft_id oft_ids oft_k oft_lk oft_sk oly_anon_id oly_enc_id rb_clickid s_cid twclid vero_conv vero_id wbraid wickedid yclid";
            "security.insecure_connection_text.enabled" = true;
            "security.insecure_connection_text.pbmode.enabled" = true;
            "toolkit.coverage.opt-out" = true;
            "toolkit.telemetry.archive.enabled" = false;
            "toolkit.telemetry.bhrPing.enabled" = false;
            "toolkit.telemetry.coverage.opt-out" = true;
            "toolkit.telemetry.dap_enabled" = false;
            "toolkit.telemetry.enabled" = false;
            "toolkit.telemetry.firstShutdownPing.enabled" = false;
            "toolkit.telemetry.newProfilePing.enabled" = false;
            "toolkit.telemetry.server" = "data:,";
            "toolkit.telemetry.shutdownPingSender.enabled" = false;
            "toolkit.telemetry.unified" = false;
            "toolkit.telemetry.updatePing.enabled" = false;
            "webchannel.allowObject.urlWhitelist" = "";

            # Disable Mozilla spyware https://support.mozilla.org/en-US/kb/privacy-preserving-attribution?as=u&utm_source=inproduct
            "dom.private-attribution.submission.enabled" = false;

            # "network.dns.http3_echconfig.enabled" = true;
            # "network.dns.echconfig.enabled" = true;
            "network.dns.preferIPv6" = true;
            "network.trr.mode" = 2;
            "network.trr.custom_uri" = "https://dns.adguard-dns.com/dns-query";
            "network.trr.confirmation_telemetry_enabled" = false;
            "security.app_menu.recordEventTelemetry" = false;
            "security.protectionspopup.recordEventTelemetry" = false;

            "browser.ml.enable" = false;
            "browser.ml.chat.enabled" = false;
            "browser.ml.chat.hideFromLabs" = true;
            "browser.ml.chat.hideLabsShortcuts" = true;
            "browser.ml.chat.page" = false;
            "browser.ml.chat.page.footerBadge" = false;
            "browser.ml.chat.page.menuBadge" = false;
            "browser.ml.chat.menu" = false;
            "browser.ml.linkPreview.enabled" = false;
            "browser.ml.pageAssist.enabled" = false;
            "browser.tabs.groups.smart.enabled" = false;
            "browser.tabs.groups.smart.userEnable" = false;
            "extensions.ml.enabled" = false;
          };

          # https://gitlab.com/kira-bruneau/home-config/-/blob/main/package/firefox/default.nix
          search = {
            force = true;
            default = "ddg";
            order = [
              "ddg"
              "google"
              "perplexity"
              "claude"
              # "qwant"
              # "kagi"
              "nixpkgs"
              "nixopts"
              "hm"
              "maven"
              "github"
              "ollama"
              "hf"
            ];
            engines = {
              "bing".metaData.hidden = true;
              "ebay".metaData.hidden = true;
              "google".metaData.alias = "@g";

              "wikipedia".metaData.alias = "@w";
              "Amazon.co.uk".metaData.hidden = "@a";

              "perplexity".metaData.alias = "@p";

              perplexity = {
                name = "Perplexity";
                urls = [{
                  template = "https://www.perplexity.ai/search";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                  ];
                }];
                icon = "https://www.perplexity.ai/favicon.ico";
                definedAliases = [ "@pp" ];
              };

              claude = {
                name = "Claude";
                urls = [{
                  template = "https://claude.ai/new";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                  ];
                }];
                icon = "https://www.claude.ai/favicon.ico";
                definedAliases = [ "@c" ];
              };

              # qwant = {
              #   name = "Qwant";
              #   urls = [{
              #     template = "https://www.qwant.com/";
              #     params = [{
              #       name = "q";
              #       value = "{searchTerms}";
              #     }
              #       {
              #         name = "t";
              #         value = "web";
              #       }];
              #   }];
              #   icon = "https://www.qwant.com/favicon.ico";
              #   definedAliases = [ "@q" ];
              # };

              hf = {
                name = "Hugging Face Models";
                urls = [{
                  template = "https://huggingface.co/search/full-text";
                  params = [{
                    name = "q";
                    value = "{searchTerms}";
                  }
                    {
                      name = "type";
                      value = "model";
                    }];
                }];
                icon = "https://huggingface.co/favicon.ico";
                definedAliases = [ "@hf" ];
              };

              # kagi = {
              #   name = "Kagi";
              #   urls = [{
              #     template = "https://kagi.com/search";
              #     params = [{
              #       name = "q";
              #       value = "{searchTerms}";
              #     }];
              #   }];
              #   icon = "https://kagi.com/favicon.ico";
              #   definedAliases = [ "@k" ];
              # };

              # leta = {
              #   name = "Leta";
              #   urls = [{
              #     template = "https://leta.mullvad.net/search";
              #     params = [{
              #       name = "q";
              #       value = "{searchTerms}";
              #     }];
              #   }];
              #   icon = "https://leta.mullvad.net/favicon.ico";
              #   definedAliases = [ "@l" ];
              # };

              maven = {
                name = "Maven";
                urls = [{
                  template = "https://search.maven.org/search";
                  params = [{
                    name = "q";
                    value = "{searchTerms}";
                  }];
                }];
                icon = "http://search.maven.org/favicon.ico";
                #icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                definedAliases = [ "@m2" ];
              };

              github = {
                name = "GitHub";
                urls = [{
                  template = "https://github.com/search";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                    {
                      name = "ref";
                      value = "opensearch";
                    }
                    {
                      name = "type";
                      value = "code";
                    }
                  ];
                }];
                #icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                icon = "https://github.com/favicon.ico";
                definedAliases = [ "@gh" ];
              };

              nixpkgs = {
                name = "Nix Packages";
                urls = [{
                  template = "https://search.nixos.org/packages";
                  params = [
                    {
                      name = "channel";
                      value = "unstable";
                    }
                    {
                      name = "from";
                      value = "0";
                    }
                    {
                      name = "size";
                      value = "50";
                    }
                    {
                      name = "sort";
                      value = "relevance";
                    }
                    {
                      name = "type";
                      value = "packages";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                  ];
                }];
                icon =
                  "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                definedAliases = [ "@np" ];
              };
              nixopts = {
                name = "Nix Options";
                urls = [{
                  template = "https://search.nixos.org/options";
                  params = [
                    {
                      name = "channel";
                      value = "unstable";
                    }
                    {
                      name = "from";
                      value = "0";
                    }
                    {
                      name = "size";
                      value = "50";
                    }
                    {
                      name = "sort";
                      value = "relevance";
                    }
                    {
                      name = "type";
                      value = "packages";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                  ];
                }];
                icon =
                  "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                definedAliases = [ "@no" ];
              };

              hm = {
                name = "Home Manager";
                urls = [{
                  template =
                    "https://home-manager-options.extranix.com/";
                  params = [{
                    name = "query";
                    value = "{searchTerms}";
                  }
                    { name = "release"; value = "master"; }];
                }];
                icon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
                definedAliases = [ "@hm" ];
              };

              ollama = {
                name = "Ollama";
                urls = [{
                  template =
                    "https://ollama.com/search";
                  params = [{
                    name = "q";
                    value = "{searchTerms}";
                  }];
                }];
                icon = "https://ollama.com/public/icon-32x32.png";
                definedAliases = [ "@llm" ];
              };

              # missing searches: nur, flakehub

              btdig = {
                name = "btdig";
                urls = [{
                  template = "https://btdig.com/search?order=0";
                  params = [
                    {
                      name = "order";
                      value = "0";
                    }
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                  ];
                }];
                icon = "https://btdig.com/favicon.ico";
                definedAliases = [ "@bt" ];
              };

            };
          };

        };

      };
    };

    xdg = lib.mkIf cfg-meta.isLinux (xdg_associate {
      schemes = [
        "x-scheme-handler/http"
        "application/xhtml+xml"
        "text/html"
        "x-scheme-handler/https"
      ];
      desktopfile = "firefox.desktop";
    });

  };
}
