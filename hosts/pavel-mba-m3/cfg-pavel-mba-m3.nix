{ config, cfg-meta, import_if_exists, cfg-const, ... }:

{
  imports =
    [
      "${cfg-meta.paths.secrets}/pavel/age-rekey-pavel-mba-m3.nix"
    ];

  smind = {
    darwin.sysconfig.enable = true;
    darwin.brew.enable = true;
    home-manager.enable = true;
  };

  # age.secrets = {
  #   id_ed25519 = {
  #     rekeyFile = "${cfg-meta.paths.secrets}/pavel/id_ed25519.age";
  #     owner = "pavel";
  #     group = "users";
  #   };

  #   builder-key = {
  #     rekeyFile = "${cfg-meta.paths.secrets}/pavel/builder-key.age";
  #     owner = "pavel";
  #     group = "users";
  #   };

  #   "id_ed25519.pub" = {
  #     rekeyFile = "${cfg-meta.paths.secrets}/pavel/id_ed25519.pub.age";
  #     owner = "pavel";
  #     group = "users";
  #   };

  #   nexus-oss-sonatype = {
  #     rekeyFile = "${cfg-meta.paths.secrets}/pavel/nexus-oss-sonatype.age";
  #     # owner = "root";
  #     # group = "nixbld";
  #     owner = "pavel";
  #     group = "users";
  #     mode = "440";
  #   };
  # };

  users.users.pavel = {
    home = "/Users/pavel";
    openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
  };

  system.defaults.screencapture = { location = "~/Desktop/Screenshots"; };

  home-manager.users.pavel = import ./home-pavel.nix;
}
