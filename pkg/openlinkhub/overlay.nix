final: prev: {
  openlinkhub = prev.openlinkhub.overrideAttrs (old: {
    version = "0.9.3";
    src = prev.fetchFromGitHub {
      owner = "jurkovic-nikola";
      repo = "OpenLinkHub";
      tag = "0.9.3";
      hash = "sha256-eKguWIXJP0LgFu2qDMThZaH5n1x6PCVibngV83TUYlU=";
    };
    # Current nixpkgs is 0.9.4; the pinned 0.9.3 tag's go.sum yields a
    # different module set (hash measured from the fixed-output fetch).
    vendorHash = "sha256-d0tA2XVDF/PzmBKqBSjfKJ3C3Lt0gMi3i2bx5LKRgj8=";
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
