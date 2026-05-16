{ config, lib, pkgs, inputs, mkIntelXpuOpenclBypassEnv, ... }:

# Opinionated wrapper around utensils/comfyui-nix's `services.comfyui`:
#   * picks the right GPU backend per host (cuda / rocm / xpu)
#   * applies the same curated set of custom nodes across all hosts
#   * for `xpu`: stacks the Battlemage-only fixes we need on top —
#       the L0 → OpenCL UR adapter bypass (`sycl-force-platform-l0`
#       + env triple) and a rebuilt ComfyUI source that drops
#       comfyui-nix's CUDA-only cpu-fallback patch in favour of an
#       XPU-aware variant.
#
# Hosts opt in by setting `smind.services.comfyui.enable = true` and
# `gpuSupport = "cuda" | "rocm" | "xpu"`. Everything else
# (listenAddress, port, openFirewall, customNodes, manager) is
# pre-filled to sensible defaults; override per-host as needed via the
# vanilla `services.comfyui.*` knobs (which take precedence — this
# module uses `mkDefault`).

let
  cfg = config.smind.services.comfyui;

  # The XPU-fixed package we built in pkg/.../comfyui-xpu fix path.
  # Only relevant when gpuSupport = "xpu".
  xpuFixedPackage =
    let
      origXpu = inputs.comfyui-nix.packages.${pkgs.stdenv.hostPlatform.system}.xpu;

      comfyuiRaw = pkgs.fetchFromGitHub {
        owner = "Comfy-Org";
        repo = "ComfyUI";
        rev = "3086026401180c9216bcb6ace442a4e3587d2c66";
        hash = "sha256-rfAF32TfVt/oVInV5Absky1PqMFQWiBd+huYrJFhHc0=";
      };

      comfyuiSrcFixed = pkgs.applyPatches {
        name = "comfyui-src-xpu-aware";
        src = comfyuiRaw;
        patches = [
          # Keep the LTX video compat patch.
          "${inputs.comfyui-nix}/nix/patches/comfyui-ltxvideo-compat.patch"
          # Deliberately skip comfyui-cpu-fallback.patch — XPU-blind.
        ];
        # Replace the upstream patch's intent with a backend-aware
        # version: fall back to CPU only when NO supported GPU
        # backend is reachable.
        postPatch = ''
          substituteInPlace comfy/model_management.py \
            --replace-fail "cpu_state = CPUState.GPU" "cpu_state = CPUState.GPU
# (comfyui-xpu-source-fix) restore the upstream patch's intent in a
# backend-aware way: fall back only when *no* GPU backend is reachable.
if cpu_state == CPUState.GPU:
    if not (torch.cuda.is_available()
            or (hasattr(torch, 'xpu') and torch.xpu.is_available())
            or (hasattr(torch.backends, 'mps') and torch.backends.mps.is_available())):
        cpu_state = CPUState.CPU"
        '';
      };
    in
    pkgs.runCommand "comfy-ui-xpu-mm-fixed"
      {
        inherit (origXpu) meta;
      }
      ''
        orig_src=$(${pkgs.gnugrep}/bin/grep -hoE \
          '/nix/store/[a-z0-9]+-source[-a-zA-Z]*' \
          ${origXpu}/bin/comfy-ui ${origXpu}/bin/comfyui \
          2>/dev/null | sort -u)
        if [ -z "$orig_src" ]; then
          echo "ERROR: no source-patched reference found in launcher" >&2
          exit 1
        fi
        mkdir -p $out
        cp -r --no-preserve=mode --reflink=auto ${origXpu}/. $out/
        chmod -R +w $out
        for f in $out/bin/*; do
          [ -f "$f" ] || continue
          ${pkgs.gnused}/bin/sed -i "s|$orig_src|${comfyuiSrcFixed}|g" "$f"
        done
      '';

  # Curated custom-node set, shared across all hosts. Add new entries
  # here once and they land on every comfyui-enabled host.
  curatedCustomNodes = {
    # ClownsharkBatwing/RES4LYF — ~115 sampler types, noise inversion,
    # advanced img2img toolkit. Provides ReAuraPatcher,
    # ConditioningDownsample (T5), ModelSamplingAdvancedResolution,
    # ClownsharKSampler, SharkSampler, …
    RES4LYF = pkgs.fetchFromGitHub {
      owner = "ClownsharkBatwing";
      repo = "RES4LYF";
      rev = "1c9bf61792ba585ad2460c998f62ae75f7ca982b";
      hash = "sha256-61cgXEDWpHdmDvTXXpYpfocpKLD5uB7enIAVWA4+YGo=";
    };

    # calcuis/gguf — provides the plain-named `LoaderGGUF`,
    # `{Clip,DualClip,TripleClip,QuadrupleClip,AudioEncoder}LoaderGGUF`,
    # `VaeGGUF`, plus GGUF conversion utilities. Distinct from
    # comfyui-nix's bundled city96/ComfyUI-GGUF (whose nodes are
    # named `UnetLoaderGGUF`, `DualCLIPLoaderGGUF`, …) — the two
    # coexist cleanly.
    gguf = pkgs.fetchFromGitHub {
      owner = "calcuis";
      repo = "gguf";
      rev = "4ef6a641b825a7b10336d101da6b5a6150f88a43";
      hash = "sha256-vUm71zCVZ29Ly5nMEMhEfmeU81jS2SWGFSR0GR6BEQk=";
    };
  };
in
{
  options.smind.services.comfyui = {
    enable = lib.mkEnableOption "ComfyUI (image-gen node-graph UI) via comfyui-nix";

    gpuSupport = lib.mkOption {
      type = lib.types.enum [ "cuda" "rocm" "xpu" "none" ];
      description = ''
        Which GPU backend ComfyUI's torch wheel should target.
        `xpu` on Battlemage (Arc Pro B70) automatically pulls in the
        OpenCL UR adapter bypass — see
        `smind.hw.intel.gpu.xpu.openclBackend` for the rationale.
      '';
    };

    customNodes = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = curatedCustomNodes;
      defaultText = lib.literalExpression "curated set (RES4LYF, gguf)";
      description = ''
        Custom-node packs to install. Defaults to the project-wide
        curated set. Override per-host by setting to a different
        attrset or by extending with `//`.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Common defaults (use mkDefault so per-host can override cheaply).
    {
      services.comfyui = {
        enable = true;
        inherit (cfg) gpuSupport customNodes;

        # Listen on all interfaces — home-LAN trust model, router walls
        # off WAN. Same convention as ollama / sd.cpp-webui.
        listenAddress = lib.mkDefault "0.0.0.0";
        port = lib.mkDefault 8188;
        openFirewall = lib.mkDefault true;

        # Manager works against comfyui-nix's pinned nixpkgs (where the
        # comfyui-manager 4.1 wheel's deps are satisfied).
        enableManager = lib.mkDefault true;
      };
    }

    # XPU-specific extras: the L0 → OpenCL bypass + the source-patch
    # variant of comfy-ui that handles XPU in cpu_state initialisation.
    (lib.mkIf (cfg.gpuSupport == "xpu") {
      services.comfyui = {
        package = lib.mkDefault xpuFixedPackage;
        environment = lib.mkDefault (mkIntelXpuOpenclBypassEnv {
          shim = pkgs.sycl-force-platform-l0;
        });
      };
    })
  ]);
}
