final: prev: {
  openlinkhub = prev.openlinkhub.overrideAttrs (old: {
    version = "0.9.3";
    src = prev.fetchFromGitHub {
      owner = "jurkovic-nikola";
      repo = "OpenLinkHub";
      tag = "0.9.3";
      hash = "sha256-eKguWIXJP0LgFu2qDMThZaH5n1x6PCVibngV83TUYlU=";
    };
    passthru = (old.passthru or { }) // {
      assets = {
        root = "${final.openlinkhub}/opt/OpenLinkHub";
        static = "${final.openlinkhub}/opt/OpenLinkHub/static";
        web = "${final.openlinkhub}/opt/OpenLinkHub/web";
        database = "${final.openlinkhub}/opt/OpenLinkHub/database";
      };
    };
  });
}
