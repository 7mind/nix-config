builders:
{
  nixos = [
    (builders.make-nixos-x86_64 {
      hostname = "testbench";
      homes = host: [
        (builders.make-home { source = "pavel-testbench"; username = "pavel"; inherit host; })
        (builders.make-home { source = "root"; username = "root"; inherit host; })
      ];
    })
  ];

  darwin = [ ];

  home = [ (builders.make-home (import ./home/pavel-ubuntu.nix)) ];
}
