{
  lib,
  runCommand,
}:

# Python startup hook that undoes comfyui-nix's `comfyui-cpu-fallback.patch`
# for hosts that use Intel XPU instead of NVIDIA CUDA.
#
# The upstream patch (intentionally) injects this block into
# `comfy/model_management.py` near line 95:
#
#   if cpu_state == CPUState.GPU:
#       if not torch.cuda.is_available():
#           cpu_state = CPUState.CPU
#
# — "fallback to CPU if no NVIDIA GPU". It checks only CUDA; on a system
# with `torch.xpu.is_available() == True` but no CUDA (i.e. ours), the
# patch flips the state to CPU even though ComfyUI's own `is_intel_xpu()`
# would (correctly) return True. The patched ComfyUI then loads every
# weight tensor on CPU and runs the whole forward pass on the host CPU
# (32 GB resident, 600% across cores, 0% GPU activity — exactly what
# we observed).
#
# This sitecustomize.py installs an import hook that detects when
# `comfy.model_management` is loaded and, if XPU is available but
# `cpu_state` got clobbered to CPU, resets it to GPU. The fix is
# minimally invasive: it does *not* override the broader CPU-fallback
# behaviour, only the XPU-specific case the upstream patch missed.
#
# Consumed by setting PYTHONPATH=${this}/lib on the systemd unit; Python
# auto-imports any `sitecustomize` module found on `sys.path` during
# startup, before user code runs (see `site` module docs).
#
# Drop this whole derivation when comfyui-nix fixes its patch — issue to
# file: utensils/comfyui-nix → make `comfyui-cpu-fallback.patch` check
# `torch.xpu.is_available()` and `torch.mps.is_available()` too.

runCommand "comfyui-xpu-cpu-state-fix" { } ''
  mkdir -p $out/lib
  cat > $out/lib/sitecustomize.py <<'EOF'
"""Reset comfy.model_management.cpu_state to GPU when XPU is available.

Workaround for the over-eager CPU-fallback patch in
utensils/comfyui-nix (`nix/patches/comfyui-cpu-fallback.patch`) which
only checks CUDA, not XPU/MPS.
"""

import sys
import importlib.abc
import importlib.machinery


class _ComfyMMLoader(importlib.abc.Loader):
    def __init__(self, orig_loader):
        self._orig = orig_loader

    def create_module(self, spec):
        if hasattr(self._orig, "create_module"):
            return self._orig.create_module(spec)
        return None

    def exec_module(self, module):
        self._orig.exec_module(module)
        try:
            import torch
            CPUState = module.CPUState
            if torch.xpu.is_available() and module.cpu_state == CPUState.CPU:
                module.cpu_state = CPUState.GPU
                sys.stderr.write(
                    "[comfyui-xpu-cpu-state-fix] forced cpu_state = GPU "
                    "(xpu available, upstream patch had clobbered it to CPU)\n"
                )
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[comfyui-xpu-cpu-state-fix] patch failed: {e!r}\n")


class _Finder(importlib.abc.MetaPathFinder):
    target = "comfy.model_management"

    def __init__(self):
        self._done = False

    def find_spec(self, name, path=None, target=None):
        if self._done or name != self.target:
            return None
        # Find the real spec via the other finders, then wrap its loader.
        for finder in list(sys.meta_path):
            if finder is self:
                continue
            try:
                spec = finder.find_spec(name, path, target)
            except (AttributeError, TypeError):
                continue
            if spec is not None and spec.loader is not None:
                self._done = True
                spec.loader = _ComfyMMLoader(spec.loader)
                return spec
        return None


sys.meta_path.insert(0, _Finder())
EOF
''
