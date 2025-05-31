builders: {
  nixos = [
    (builders.make-nixos-x86_64 "pavel-am5")
    (builders.make-nixos-x86_64 "vm")
    (builders.make-nixos-x86_64 "nas")

    (builders.make-nixos-aarch64 "o1")
    (builders.make-nixos-aarch64 "o2")
  ];

  darwin = [
    (builders.make-darwin-aarch64 "pavel-mba-m3")
  ];
}

