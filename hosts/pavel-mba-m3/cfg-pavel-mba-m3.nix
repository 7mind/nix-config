{ config, cfg-meta, import_if_exists, cfg-const, ... }:

{
  imports =
    [
      # "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
    ];

  # smind = {
  # };

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



  #home-manager.users.pavel = import ./home-pavel.nix;


}
