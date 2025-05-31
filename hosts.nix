builders: {
  nixos = [
    (builders.make-nixos-x86_64 "pavel-am5")
  ];

  darwin = [
    (builders.make-darwin-aarch64 "pavel-mba-m3")
  ];
}

