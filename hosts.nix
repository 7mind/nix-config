builders: {
  nixos = [
    (builders.make-nixos-x86_64 "pavel-am5")
    (builders.make-nixos-x86_64 "pavel-fw")
    (builders.make-nixos-x86_64 "testbench")
    (builders.make-nixos-aarch64 "raspi5m")
  ];

  darwin = [
    (builders.make-darwin-aarch64 "pavel-mba-m3")
  ];
}
