{
  description = "WCAG-compliant terminal color theme tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.cudaSupport = true;
        };

        cudaPackages = pkgs.cudaPackages;

        colorOptimizer = pkgs.stdenv.mkDerivation {
          pname = "color-optimizer";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [
            cudaPackages.cuda_nvcc
            pkgs.cmake
          ];

          buildInputs = [
            cudaPackages.cuda_cudart
            cudaPackages.cuda_cccl
            cudaPackages.libcurand
          ];

          buildPhase = ''
            # Use PTX for forward compatibility with newer GPUs (Blackwell, etc.)
            nvcc -O3 -gencode arch=compute_75,code=sm_75 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_90,code=compute_90 -o color-optimizer color-optimizer.cu -lcurand
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp color-optimizer $out/bin/
          '';
        };

      in {
        packages = {
          default = colorOptimizer;
          optimizer = colorOptimizer;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.python3
            cudaPackages.cuda_nvcc
            cudaPackages.cuda_cudart
            cudaPackages.cuda_cccl
            cudaPackages.libcurand
          ];

          shellHook = ''
            # Add nvidia driver libraries to path (NixOS)
            export LD_LIBRARY_PATH=/run/opengl-driver/lib:''${LD_LIBRARY_PATH:-}

            echo "CUDA color optimizer dev shell"
            echo "Build: nvcc -O3 -o color-optimizer color-optimizer.cu -lcurand"
            echo "Run: ./color-optimizer --help"
          '';
        };
      }
    );
}
