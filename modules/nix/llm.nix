{ pkgs, lib, config, ... }: {
  options = {
    smind.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    services.ollama = {
      enable = true;
    };

    services.tabby = {
      enable = true;
    };
  };

}
