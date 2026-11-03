{ inputs, ... }:
{
  imports = [
    inputs.ponygirls.homeManagerModules.agenticServicesServer
    inputs.ponygirls.homeManagerModules.chronicleServer
  ];
}
