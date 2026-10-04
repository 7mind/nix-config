builders:
let
  home = {
    pavel-am5-pavel = builders.make-home-x86_64 { hostname = "pavel-am5"; username = "pavel"; };
    pavel-am5-root = builders.make-home-x86_64 { hostname = "pavel-am5"; username = "root"; };
    pavel-fw-pavel = builders.make-home-x86_64 { hostname = "pavel-fw"; username = "pavel"; };
    pavel-fw-root = builders.make-home-x86_64 { hostname = "pavel-fw"; username = "root"; };
    pavel-trx40-pavel = builders.make-home-x86_64 { hostname = "pavel-trx40"; username = "pavel"; };
    pavel-trx40-root = builders.make-home-x86_64 { hostname = "pavel-trx40"; username = "root"; };
    pavel-mba-m3-pavel = builders.make-home-darwin-aarch64 { hostname = "pavel-mba-m3"; username = "pavel"; };
    ubuntu-pavel = builders.make-home-x86_64 { hostname = "ubuntu"; username = "pavel"; };
  };
in
{
  nixos = [
    (builders.make-nixos-x86_64 {
      hostname = "pavel-am5";
      homes = [ home.pavel-am5-pavel home.pavel-am5-root ];
    })
    (builders.make-nixos-x86_64 {
      hostname = "pavel-fw";
      homes = [ home.pavel-fw-pavel home.pavel-fw-root ];
    })
    (builders.make-nixos-x86_64 {
      hostname = "pavel-trx40";
      homes = [ home.pavel-trx40-pavel home.pavel-trx40-root ];
    })
  ];

  darwin = [
    (builders.make-darwin-aarch64 {
      hostname = "pavel-mba-m3";
      homes = [ home.pavel-mba-m3-pavel ];
    })
  ];

  home = builtins.attrValues home;
}
