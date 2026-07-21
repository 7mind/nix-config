{ config, lib, ... }:

let
  ownerSecretsEnabled = config.smind.age.enable && config.smind.age.load-owner-secrets;

  # Prevent a host from using itself as a remote builder (causes deadlock).
  # Compare short hostnames: extract first component of builder FQDN (e.g. "vm" from "vm.home.7mind.io").
  builderShortName = machine: builtins.head (lib.splitString "." machine.hostName);
  isSelf = machine: builderShortName machine == config.networking.hostName;

  allBuildMachines = [
      # Threadripper 3970x box (32 cores / 64 threads, dual GPU). May
      # be powered off or otherwise unreachable; relies on
      # `nix.settings.fallback = true` below so a missing builder
      # degrades to a local build instead of failing the rebuild.
      # publicHostKey carried over from the prior `pavel-nix` install
      # (the host SSH ed25519 key was preserved across the takeover).
      {
        hostName = "pavel-trx40.home.7mind.io";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        maxJobs = 3;
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUxqclA0bHIrV1NnTDNrNWVBNis0Q0dZbXR6NlVpdEltWSszUkFSYU0wcnkgcm9vdEBmcmVzaG5peAo=";
        # vm's x86 speedFactor is 2; the Threadripper benchmarks well
        # over 4x faster (per the user), and Nix prefers higher
        # speedFactor builders for the same system. Keep some headroom
        # so future-faster builders can slot in above without
        # renumbering.
        speedFactor = 16;
        supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
        mandatoryFeatures = [ ];
      }

      # Same Threadripper as the x86_64 entry above, exposed as an
      # aarch64-linux builder via the binfmt/QEMU emulation enabled in
      # hosts/pavel-trx40/cfg-pavel-trx40.nix. Per-job throughput is
      # below a native ARM64 box (o0/o1/o2), but 32C/64T + the userspace
      # QEMU translator running on Zen2 still beats local emulation on
      # vm by a wide margin, and frequently the small o0/o1/o2 boxes too
      # — so this entry is given a higher speedFactor than the native
      # ones to make the scheduler prefer it whenever pavel-trx40 is
      # up. The `nix.settings.fallback = true` below keeps vm building
      # locally if pavel-trx40 is offline. Drops "kvm" because QEMU
      # user-mode emulation provides no virtualisation acceleration to
      # aarch64 derivations.
      {
        hostName = "pavel-trx40.home.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        maxJobs = 3;
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUxqclA0bHIrV1NnTDNrNWVBNis0Q0dZbXR6NlVpdEltWSszUkFSYU0wcnkgcm9vdEBmcmVzaG5peAo=";
        speedFactor = 10;
        supportedFeatures = [ "benchmark" "big-parallel" ];
        mandatoryFeatures = [ ];
      }

      {
        hostName = "vm.home.7mind.io";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        maxJobs = 2;
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSURRWkVOWnVzZUl6aFhrYnZNYnFhVS91ZlM0WExXOTV5WS9EUHJvZG5ZVmIgcm9vdEBuaXhvcwo=";
        speedFactor = 2;
        supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
        mandatoryFeatures = [ ];
      }

      {
        hostName = "vm.home.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        maxJobs = 1;
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSURRWkVOWnVzZUl6aFhrYnZNYnFhVS91ZlM0WExXOTV5WS9EUHJvZG5ZVmIgcm9vdEBuaXhvcwo=";
        speedFactor = 1;
        supportedFeatures = [ ];
        mandatoryFeatures = [ ];
      }

      {
        hostName = "o0.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtaU3FyUjVSb0FUV2Z2ZFdPUkdHU1FGRTJFTzJpSlA5S3Z2WWtRbVE2aG8gcm9vdEBuaXhvcwo=";
        maxJobs = 4;
        speedFactor = 8;
        supportedFeatures = [ "benchmark" "big-parallel" ];
        mandatoryFeatures = [ ];
      }

      {
        hostName = "o1.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSU1ybldtV3hBa25nMXp4NktjUXVHYUpnQ1JWYUxjaDl4TXZrVnpTZSs2ekkgcm9vdEBuaXhvcwo=";
        maxJobs = 4;
        speedFactor = 8;
        supportedFeatures = [ "benchmark" "big-parallel" ];
        mandatoryFeatures = [ ];
      }

      {
        hostName = "o2.7mind.io";
        system = "aarch64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = lib.mkIf ownerSecretsEnabled "${config.age.secrets.builder-key.path}";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUZPRFREbUZsUHVKM1hIVzI0TFlMY0pyVFpGNStmZzZITlVpSEtLdUpYZkQgcm9vdEBuaXhvcwo=";
        maxJobs = 4;
        speedFactor = 4;
        supportedFeatures = [ "benchmark" "big-parallel" ];
        mandatoryFeatures = [ ];
      }

    ];
in
{
  options = {
    smind.infra.nix-build.enable = lib.mkEnableOption "distributed nix builds";
  };

  config = lib.mkIf config.smind.infra.nix-build.enable {
    nix.distributedBuilds = true;

    # If every remote builder declines the job (offline, ssh timeout,
    # no matching system+features), fall through to a local build
    # instead of failing. Pairs with the short `connect-timeout = 3`
    # set in modules/nix-generic/attic-cache.nix — together they make
    # an offline pavel-trx40/o0/o1/o2 non-fatal.
    nix.settings.fallback = true;

    nix.extraOptions = ''
      	  builders-use-substitutes = true
      	'';

    # obtain host public key: base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub
    nix.buildMachines = builtins.filter (machine: !isSelf machine) allBuildMachines;

  };
}
