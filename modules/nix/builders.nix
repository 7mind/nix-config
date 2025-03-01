{ config, lib, ... }:

{
  options = {
    smind.infra.nix-build.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.infra.nix-build.enable {
    nix.distributedBuilds = true;
    nix.extraOptions = ''
      	  builders-use-substitutes = true
      	'';

    # obtain host public key: base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub
    nix.buildMachines = [
      {
        hostName = "pavel-nix.home.7mind.io";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        maxJobs = 2;
        sshKey = "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUxqclA0bHIrV1NnTDNrNWVBNis0Q0dZbXR6NlVpdEltWSszUkFSYU0wcnkgcm9vdEBmcmVzaG5peAo=";
        speedFactor = 32;
        supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
        mandatoryFeatures = [ ];
      }

      # {
      #   hostName = "vm.home.7mind.io";
      #   system = "x86_64-linux";
      #   protocol = "ssh-ng";
      #   sshUser = "root";
      #   maxJobs = 1;
      #   sshKey = "${config.age.secrets.builder-key.path}";
      #   publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSURRWkVOWnVzZUl6aFhrYnZNYnFhVS91ZlM0WExXOTV5WS9EUHJvZG5ZVmIgcm9vdEBuaXhvcwo=";
      #   speedFactor = 2;
      #   supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
      #   mandatoryFeatures = [ ];
      # }

      {
        hostName = "o1.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSU1ybldtV3hBa25nMXp4NktjUXVHYUpnQ1JWYUxjaDl4TXZrVnpTZSs2ekkgcm9vdEBuaXhvcwo=";
        maxJobs = 4;
        speedFactor = 4;
        supportedFeatures = [ "benchmark" "big-parallel" ];
        mandatoryFeatures = [ ];
      }

      {
        hostName = "o2.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUZPRFREbUZsUHVKM1hIVzI0TFlMY0pyVFpGNStmZzZITlVpSEtLdUpYZkQgcm9vdEBuaXhvcwo=";
        maxJobs = 4;
        speedFactor = 2;
        supportedFeatures = [ "benchmark" "big-parallel" ];
        mandatoryFeatures = [ ];
      }

    ];


  };
}
