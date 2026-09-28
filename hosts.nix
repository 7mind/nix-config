builders: {
  nixos = [
    (builders.make-nixos-x86_64 "pavel-am5")
    (builders.make-nixos-x86_64 "pavel-fw")
    (builders.make-nixos-x86_64 "pavel-trx40")
  ];

  darwin = [
    (builders.make-darwin-aarch64 "pavel-mba-m3")
  ];

  home = [
    (builders.make-home-x86_64 { hostname = "ubuntu"; username = "pavel"; })
  ];
}
