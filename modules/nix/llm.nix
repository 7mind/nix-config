{ pkgs, lib, config, ... }:
# let
#   pinPackage =
#     { name
#     , commit
#     , sha256
#     ,
#     }:
#     (import
#       (builtins.fetchTarball {
#         inherit sha256;
#         url = "https://github.com/NixOS/nixpkgs/archive/${commit}.tar.gz";
#       })
#       { system = pkgs.system; }).${name};
# in
{
  options = {
    smind.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    environment.systemPackages = with pkgs; [
      lmstudio
      jan
    ];

    services.ollama = {
      enable = true;
      # https://github.com/NixOS/nixpkgs/issues/375910
      package = pkgs.ollama-rocm;
      # package = (pinPackage {
      #   name = "ollama";
      #   commit = "d0169965cf1ce1cd68e50a63eabff7c8b8959743";
      #   sha256 = "sha256:1hh0p0p42yqrm69kqlxwzx30m7i7xqw9m8f224i3bm6wsj4dxm05";
      # });
      rocmOverrideGfx = "11.0.0";
      acceleration = "rocm";
      port = 11434;
      loadModels = [
        "llama3.3"
        "llama3.1:8b"

        "nomic-embed-text"

        "deepseek-r1:32b"

        "qwen:32b"
        "qwen2.5:32b"
        "qwen2.5-coder:32b"
        
        "aratan/qwen2.5-14bu:latest"


        # "starcoder2:7b"
        # "starcoder2:15b"
        # "dolphincoder:15b"
        # "mistral"
        # "gemma:7b"
        # "codellama:13b"
      ];
      environmentVariables = {
        OLLAMA_SCHED_SPREAD = "true";
        ROCR_VISIBLE_DEVICES = "0";
      };
    };

    #services.tabby = {
    #  enable = true;
    #  acceleration = "rocm";
    #};

    services.open-webui = {
      enable = true;
      environment = {
        OLLAMA_API_BASE_URL = "http://127.0.0.1:11434";
        WEBUI_AUTH = "False";
      };
    };
  };

}
