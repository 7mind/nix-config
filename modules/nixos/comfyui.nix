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

      # Extra Python wheels needed by `comfyui_controlnet_aux` preprocessors
      # that aren't already in comfyui-nix's bundled `pythonRuntime`. Built
      # against the *same* python instance (origXpu.pythonRuntime.python) so
      # torch/numpy/etc. are shared without ABI drift across two envs.
      #
      # `mediapipe` is deliberately absent — not packaged in nixpkgs
      # (TF/Bazel build dance). The affected preprocessors
      # (mesh_graphormer, mediapipe_face) raise ImportError at load time;
      # controlnet_aux's `__init__.py` catches that per-wrapper and just
      # omits them from the AIO_Preprocessor dropdown.
      controlnetAuxPyRuntime = origXpu.passthru.pythonRuntime;
      controlnetAuxExtraDeps = controlnetAuxPyRuntime.python.withPackages (
        ps: with ps; [
          fvcore
          yapf
          addict
          yacs
          trimesh
          albumentations
          scikit-learn
          python-dateutil
        ]
      );
    in
    pkgs.runCommand "comfy-ui-xpu-mm-fixed"
      {
        inherit (origXpu) meta;
        nativeBuildInputs = [ pkgs.makeWrapper ];
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

        # Layer controlnet_aux's extra Python deps onto the launcher via
        # PYTHONPATH suffix. Order doesn't matter for correctness because
        # `controlnetAuxExtraDeps` is built against `pythonRuntime.python`
        # (same overridden package set as comfyui-nix's bundled env), so
        # overlapping transitive deps point at identical store paths.
        # Suffix is just so any debug `python -c 'import sys; print(sys.path)'`
        # still shows the base pythonRuntime first.
        for f in $out/bin/*; do
          [ -f "$f" ] || continue
          wrapProgram "$f" \
            --suffix PYTHONPATH : "${controlnetAuxExtraDeps}/${controlnetAuxPyRuntime.python.sitePackages}"
        done
      '';

  # Curated custom-node set, shared across all hosts. Add new entries
  # here once and they land on every comfyui-enabled host.
  curatedCustomNodes = {
    # ltdrdata/ComfyUI-Manager — the canonical Manager that users
    # know (toolbar button, Install Custom Nodes / Install Models /
    # snapshot tabs). NOT the same as Comfy-Org's pip-installed
    # `comfyui_manager` 4.x which is wired up via the
    # `--enable-manager` flag and integrates with Comfy Cloud; that
    # one doesn't expose the in-UI install flows users expect.
    "ComfyUI-Manager" = pkgs.fetchFromGitHub {
      owner = "ltdrdata";
      repo = "ComfyUI-Manager";
      rev = "871a646fd723e48ac8588052a131faf106dbbfd2";
      hash = "sha256-aYY8U1KzVeIzzkJih6F/0yPJt0qei/nPsBAJlSBUpps=";
    };

    # ciri/comfyui-model-downloader — provides three nodes:
    #   * `HF Download`        — paste a HuggingFace URL, pick folder, queue.
    #   * `CivitAI Download`   — same for Civitai (uses Manager's API key).
    #   * `Auto Model Finder`  — experimental, source-agnostic.
    # Surfaces in ComfyUI's node menu under "loaders" — no separate Manager
    # tab needed; drop a node, paste a URL, hit Queue Prompt, file lands in
    # `models/<folder>/`.
    "comfyui-model-downloader" = pkgs.fetchFromGitHub {
      owner = "ciri";
      repo = "comfyui-model-downloader";
      rev = "0e12a95b68f6079af6d294eb12f2d58739bac672";
      hash = "sha256-dfJB7Jg7b5ml2N3L9FS0h3Vd/C41OD5cWGqirKP3mU4=";
    };

    # ClownsharkBatwing/RES4LYF — ~115 sampler types, noise inversion,
    # advanced img2img toolkit. Provides ReAuraPatcher,
    # ConditioningDownsample (T5), ModelSamplingAdvancedResolution,
    # ClownsharKSampler, SharkSampler, …
    #
    # Patched here because the upstream code calls
    # `get_ext_dir(CONFIG_FILE_NAME)` which resolves to a path inside
    # its own source directory — and comfyui-nix `customNodes`
    # symlinks the source from the read-only nix store, so the first
    # `open(..., "w")` fails with EROFS at module init. We redirect
    # `config_path` to `$HOME/.config/RES4LYF/` (which is writable —
    # `/var/lib/comfyui/.config/RES4LYF/` for the service user).
    RES4LYF = pkgs.applyPatches {
      name = "RES4LYF-writable-config";
      src = pkgs.fetchFromGitHub {
        owner = "ClownsharkBatwing";
        repo = "RES4LYF";
        rev = "1c9bf61792ba585ad2460c998f62ae75f7ca982b";
        hash = "sha256-61cgXEDWpHdmDvTXXpYpfocpKLD5uB7enIAVWA4+YGo=";
      };
      postPatch = ''
        substituteInPlace res4lyf.py \
          --replace-fail \
            'get_ext_dir(CONFIG_FILE_NAME)' \
            '(os.makedirs(os.path.expanduser("~/.config/RES4LYF"), exist_ok=True) or os.path.expanduser("~/.config/RES4LYF/" + CONFIG_FILE_NAME))'
      '';
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

    # Suzie1/ComfyUI_Comfyroll_CustomNodes — the canonical "CR …" suite:
    # `CR Multi Upscale Stack`, `CR Latent Input Switch`,
    # `CR Apply Multi Upscale`, plus ~150 more (XY plot, prompt builder,
    # conditioning mixers, graphics/text/border, latent switches, …).
    # Pure-Python, no extra wheels.
    #
    # comfyui-nix's launcher (packages.nix L405-413) tries to `sed -i`
    # `nodes/nodes_graphics_text.py` at runtime to swap the hardcoded
    # `/usr/share/fonts/truetype` for the bundled-fonts dir — but
    # comfyui-nix's NixOS module wires `customNodes` via direct symlinks
    # into the read-only Nix store, so the in-place sed fails with
    # EROFS and crashes the service. We pre-apply the substitution here
    # (driven by `$COMFYUI_BASE_DIR`, which the launcher exports) so the
    # launcher's `grep -q` no longer matches and its sed is skipped.
    ComfyUI_Comfyroll_CustomNodes = pkgs.applyPatches {
      name = "ComfyUI_Comfyroll_CustomNodes-nixos-fonts";
      src = pkgs.fetchFromGitHub {
        owner = "Suzie1";
        repo = "ComfyUI_Comfyroll_CustomNodes";
        rev = "d78b780ae43fcf8c6b7c6505e6ffb4584281ceca";
        hash = "sha256-+qhDJ9hawSEg9AGBz8w+UzohMFhgZDOzvenw8xVVyPc=";
      };
      postPatch = ''
        substituteInPlace nodes/nodes_graphics_text.py \
          --replace-fail \
            'font_dir = "/usr/share/fonts/truetype"' \
            'font_dir = os.path.join(os.environ.get("COMFYUI_BASE_DIR", os.path.expanduser("~/.config/comfy-ui")), "fonts")'
      '';
    };

    # Fannovel16/comfyui_controlnet_aux — ControlNet aux preprocessors
    # (canny, depth_anything[/v2], dwpose, openpose, hed, lineart[/anime],
    # scribble, tile, normalbae, mlsd, midas, leres, zoe, segment_anything,
    # teed, pidinet, anyline, metric3d, dsine, densepose, oneformer, …)
    # and the catch-all `AIO_Preprocessor` dispatcher node.
    #
    # Dep coverage: `__init__.py` loads each preprocessor wrapper inside a
    # try/except, so missing deps degrade gracefully — only the affected
    # wrappers fail to register and are hidden from the dropdown. The
    # base comfyui-nix `pythonRuntime` already covers most needs
    # (opencv, scikit-image, matplotlib, omegaconf, ftfy, transformers,
    # huggingface-hub, onnxruntime, timm, einops, scipy, ...); the
    # remaining ones (fvcore, yacs, addict, yapf, trimesh, albumentations,
    # scikit-learn, python-dateutil) are layered onto the XPU launcher
    # via PYTHONPATH — see `controlnetAuxExtraDeps` above.
    #
    # Known gap: `mediapipe` is not in nixpkgs, so `mesh_graphormer` and
    # `mediapipe_face` won't register. Non-xpu backends would also miss
    # the python-deps layering above; we don't run any non-xpu comfyui
    # hosts today.
    comfyui_controlnet_aux = pkgs.fetchFromGitHub {
      owner = "Fannovel16";
      repo = "comfyui_controlnet_aux";
      rev = "e8b689a513c3e6b63edc44066560ca5919c0576e";
      hash = "sha256-tMmERf4y7sfuEGao7JHC7FLjBgPuViCtHxr8f9NnHzo=";
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

    xpuShim = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.sycl-force-platform-l0 or null;
      defaultText = lib.literalExpression "pkgs.sycl-force-platform-l0 (when the project overlay is in scope)";
      description = ''
        The `sycl-force-platform-l0` LD_PRELOAD shim used when
        `gpuSupport = "xpu"`. The default resolves it from the host's
        project overlay; nspawn-isolated containers (which don't apply
        the overlay) must set this explicitly via specialArgs.
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

        # `enableManager` here drives Comfy-Org's pip-installed
        # `comfyui_manager` 4.x — a different package than what users
        # think of when they say "ComfyUI Manager". Its UI doesn't
        # expose the Install Custom Nodes / Install Models flows;
        # those live in the classic `ltdrdata/ComfyUI-Manager` which
        # we bundle as a regular custom node above. Leaving this off
        # avoids two Managers fighting over the same routes.
        enableManager = lib.mkDefault false;
      };
    }

    # XPU-specific extras: the L0 → OpenCL bypass + the source-patch
    # variant of comfy-ui that handles XPU in cpu_state initialisation.
    (lib.mkIf (cfg.gpuSupport == "xpu") {
      assertions = [
        {
          assertion = cfg.xpuShim != null;
          message = ''
            smind.services.comfyui.gpuSupport = "xpu" requires
            `xpuShim` — either ensure the project overlay providing
            `pkgs.sycl-force-platform-l0` is in scope, or set
            `smind.services.comfyui.xpuShim` explicitly.
          '';
        }
      ];
      services.comfyui = {
        package = lib.mkDefault xpuFixedPackage;
        environment = lib.mkDefault (mkIntelXpuOpenclBypassEnv {
          shim = cfg.xpuShim;
        });
      };
    })

    # One-shot cleanup of an obsolete `.pth` shim from an earlier
    # workaround attempt (we briefly tried injecting a Python startup
    # hook via `comfyui_xpu_fix.pth` before we settled on the
    # source-patch approach). The file lives in the persisted venv at
    # `<dataDir>/.venv/lib/.../site-packages/aaa-xpu-fix.pth`; Python
    # logs an ImportError for it on every startup until removed.
    # Safe to drop this block once every comfyui-enabled host has
    # started at least once with this code.
    {
      systemd.services.comfyui.serviceConfig.ExecStartPre = [
        "${pkgs.coreutils}/bin/rm -f ${config.services.comfyui.dataDir}/.venv/lib/python3.12/site-packages/aaa-xpu-fix.pth"
      ];
    }
  ]);
}
