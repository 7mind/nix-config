# Zimt flake cleanup prompt

Paste this into a fresh Claude Code session opened in the
`pshirshov/zimt` repo. It briefs the agent on (a) the consumer-side
L0-bypass plumbing that just got removed in nix-config and the actual
root cause it was masking, and (b) two pre-existing build failures
that surface when nix-config tries to build the zimt-xpu Python env.

---

## Prompt body

You are working in the `pshirshov/zimt` flake repo. This repo provides
a multi-backend image-generation REPL/web UI (`xpu`, `cuda`, `rocm`,
`cpu`) as both a NixOS module (`nixosModules.default`) and per-backend
packages (`packages.x86_64-linux.zimt-{xpu,cuda,rocm,cpu}`).

### Context — what just changed downstream

A downstream nix-config consumer (`pavel/nix-config`, the `vm` host's
zimt container) was carrying a stack of "Level Zero is broken on
Battlemage" workarounds. The cumulative diagnosis is now:

The "abort at `gmm_helper/resource_info.cpp:15`" that has been
mis-attributed to `intel/compute-runtime#922` since ~2026-02 was NEVER
a compute-runtime regression on single-process workloads. It was a
**nixpkgs packaging defect**: upstream
`pkgs/by-name/in/intel-compute-runtime/package.nix` patches
`intel-graphics-compiler` into the RPATH of `libigdrcl.so` (the OpenCL
ICD) but NOT into `libze_intel_gpu.so.1` (the Level Zero driver in the
`drivers` split output). NEO dlopens IGC by name during eager device
init; with no RPATH and IGC absent from `/run/opengl-driver/lib`, the
dlopen fails and NEO's `abortUnrecoverable` routes the failure through
`gmm_helper/resource_info.cpp:15`.

The proof, on an Intel Arc Pro B70 (BMG-G31, `0x8086:0xe223`), xe-kmd
7.0.3, NixOS 26.05, against the EXACT same `libze_intel_gpu.so.1` that
was aborting:

| Setup | Result |
|---|---|
| `LD_LIBRARY_PATH=/run/opengl-driver/lib` only | abort `resource_info.cpp:15` |
| `+ ${intel-graphics-compiler}/lib` | `zeInit = 0x0`, B70 enumerates, USM allocations succeed |
| `torch.xpu.device_count()` w/ torch 2.10.0+xpu, no shim, no env override | returns 1, "Intel(R) Arc(TM) Pro B70 Graphics", 128² matmul OK |

The fix in nix-config is a single overlay-level `patchelf` extending
the `intel-compute-runtime` `postFixup` to set RPATH on the L0 driver
split, plus a 26.14 → 26.18 bump (incidental — the bump itself isn't
what fixed things).

### What the consumer dropped (so zimt's NixOS module no longer needs to support it)

The downstream zimt container was passing the following triple into
the zimt module's `extraEnvironment`:
```nix
ONEAPI_DEVICE_SELECTOR = "opencl:gpu";
OCL_ICD_VENDORS = "/run/opengl-driver/etc/OpenCL/vendors";
LD_PRELOAD = "${pkgs.sycl-force-platform-l0}/lib/libsycl_force_platform_l0.so";
```
together with a 1-symbol LD_PRELOAD shim (`sycl-force-platform-l0`)
that overrode `sycl::platform::get_backend()` to return
`ext_oneapi_level_zero` so PyTorch's hardcoded L0-only filter in
`c10/xpu/XPUFunctions.cpp:113` would admit OpenCL-backed platforms.

All three env vars and the shim are gone in the consumer now. Level
Zero works correctly with the underlying packaging fix.

### Cleanup tasks in this (zimt) repo

1. **Audit the zimt nixosModule for L0-bypass plumbing.**
   - Look for any code paths conditionally setting
     `ONEAPI_DEVICE_SELECTOR=opencl:gpu`,
     `OCL_ICD_VENDORS`, or `LD_PRELOAD` of a `sycl_force_platform_l0`
     shim.
   - Look for any documentation, comments, or knobs referencing
     `intel/compute-runtime#922`, `gmm_helper/resource_info.cpp:15`, or
     "Battlemage L0 bug" — they were describing a symptom, not a real
     compute-runtime regression for single-process workloads. Either
     delete the references or rewrite them to point at "ensure IGC is
     on `libze_intel_gpu.so.1`'s RPATH or on the library search path".
   - The zimt flake bundles its own torch/IPEX wheels for the `xpu`
     backend. If any of them were patched to work around the abort,
     check whether those patches are still needed (likely not).

2. **Fix the broken Python-wheel fetcher in the XPU backend.**
   When downstream `./setup vm -s` tried to build `zimt-xpu`, every
   Intel/oneAPI Python wheel failed to download with HTTP 404:
   ```
   trying https://files.pythonhosted.org/packages/source/dpcpp_cpp_rt/dpcpp_cpp_rt-2025.3.2-py2.py3-none-manylinux_2_28_x86_64.whl
   curl: (22) The requested URL returned error: 404
   ```
   Same failure for `intel_cmplr_lib_rt`, `intel_cmplr_lib_ur`,
   `intel_cmplr_lic_rt`, `intel_opencl_rt`, `intel_openmp`, `intel_pti`,
   `intel_sycl_rt`, `impi_rt`, `mkl`, `oneccl`, `oneccl_devel`,
   `onemkl_license`, `onemkl_sycl_{blas,dft,lapack,rng,sparse}`, `tbb`,
   `umf`, `triton-xpu`, `torchvision`, `torch`. All `manylinux_2_28`
   wheels.

   Root cause: the URL pattern
   `files.pythonhosted.org/packages/source/<pkg>/<filename>` only
   serves **sdists**. PyPI does not serve `.whl` files under
   `/packages/source/`; binary wheels live at content-addressed paths
   like `files.pythonhosted.org/packages/<aa>/<bb>/<long_hex>/<filename>`.

   The flake is almost certainly using `fetchPypi { ... }` with
   default args (which generates the `/packages/source/` URL) for what
   should be `fetchurl` against the JSON-API-resolved CDN URL, or
   `fetchPypi { format = "wheel"; dist = "py2.py3"; python = "py3"; }`
   (which historically tried a `/packages/<py-tag>/<first>/<pkg>/`
   prefix that PyPI removed). Either way: switch to a fetcher that
   resolves the content-hashed URL via the PyPI JSON API (the
   `pypi-2-nix`-style approach, or `pip2nix`/`uv2nix`, or a one-shot
   pin of the content URL) and update the lockfile.

3. **Fix the placeholder hash on diffusers.**
   ```
   error: hash mismatch in fixed-output derivation '/nix/store/.../source.drv':
            specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
               got:    sha256-HiFak6uSAQrHxCUPwQcRzJkOmym7wflOXO3IE5zv50Y=
   error: Cannot build '/nix/store/...python3.13-diffusers-0.39.0.dev0.drv'.
   ```
   Somebody left a `sha256-AAAAAA…` fakeHash placeholder in the
   `diffusers` derivation. The build prints the real hash
   (`sha256-HiFak6uSAQrHxCUPwQcRzJkOmym7wflOXO3IE5zv50Y=`); paste it
   in.

4. **Validate after fixes** by running:
   ```
   nix build .#zimt-xpu
   ```
   This builds the same derivation the downstream container depends
   on. Once it returns a store path, the consumer can re-enable the
   `./containers/zimt.nix` import and run `./setup vm -s` cleanly.

5. **Fix `libsycl.so.8: cannot open shared object file` at zimt-xpu
   startup.** Once the wheels do download, `zimt.service` still
   restart-loops with:
   ```
   File "…/torch/__init__.py", line 444, in <module>
     from torch._C import *  # noqa: F403
   ImportError: libsycl.so.8: cannot open shared object file: No such file or directory
   ```
   `libsycl.so.8` is shipped inside the Intel runtime wheels —
   typically under `intel_cmplr_lib_rt/lib/` and/or `torch/lib/` after
   the `torch+xpu` wheel install. The library is in the closure (some
   wheel unpacked it), but the loader can't find it because the
   Python env's site-packages directory layout doesn't end up on the
   dynamic linker's search path the way the upstream pip wheels
   assume. Common fixes:
    - Run `autoPatchelfHook` on each Intel runtime wheel so each `.so`
      gets its DT_RUNPATH set explicitly to point at its bundled
      `lib/` siblings.
    - Or set `LD_LIBRARY_PATH` / `extraEnvironment` on `zimt.service`
      to include the wheel-installed `lib/` directories — fragile but
      the simplest unblock.
    - Or use `python.pkgs.buildPythonPackage`-level `propagatedNativeBuildInputs`
      hooks that wire the runtime libs into Python's `torch.lib`
      `torch._dl` discovery the way the upstream wheels expect.
   The cleanest path is `autoPatchelfHook`-style RPATH-fixing on the
   binary wheels.

6. **Optional: bump the pinned nixpkgs.** The flake currently pins
   `nixpkgs nixos-unstable d233902339c02a9c334e7e593de68855ad26c4cb`.
   The PyPI URL breakage may have been introduced by a fetchPypi
   refactor in nixpkgs. Compare against current `nixos-unstable` HEAD;
   bumping might be the cheapest fix.

### Hard requirements

- Do NOT re-introduce the OpenCL-bypass triple or any
  `sycl-force-platform-l0`-style shim — the underlying Level Zero
  path is fixed in the consumer's overlay.
- Do NOT pin to compute-runtime ≤ 26.05; the consumer is on 26.18 and
  has no regressions.
- Anything you ship from a binary wheel must be re-fetchable
  reproducibly without depending on PyPI's deprecated URL patterns.

Read the flake, list every place that touches the topics above, and
propose a minimal patch set before making changes.
