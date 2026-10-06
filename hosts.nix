builders:
{
  nixos = [
    (builders.make-nixos-x86_64 {
      hostname = "pavel-am5";
      homes = host: [
        (builders.make-home { source = "pavel-am5"; username = "pavel"; inherit host; })
        (builders.make-home { source = "root"; username = "root"; inherit host; })
      ];
    })
    (builders.make-nixos-x86_64 {
      hostname = "pavel-fw";
      homes = host: [
        (builders.make-home { source = "pavel-fw"; username = "pavel"; inherit host; })
        (builders.make-home { source = "root"; username = "root"; inherit host; })
      ];
    })
    (builders.make-nixos-x86_64 {
      hostname = "pavel-trx40";
      homes = host: [
        (builders.make-home { source = "pavel-trx40"; username = "pavel"; inherit host; })
        (builders.make-home { source = "root"; username = "root"; inherit host; })
      ];
    })
  ];

  darwin = [
    (builders.make-darwin-aarch64 {
      hostname = "pavel-mba-m3";
      homes = host: [
        (builders.make-home { source = "pavel-mba-m3"; username = "pavel"; inherit host; })
      ];
    })
  ];

  home = [ (builders.make-home (import ./home/pavel-ubuntu.nix)) ];
}
