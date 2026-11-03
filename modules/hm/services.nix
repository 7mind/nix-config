{ inputs, ... }:
{
  imports = [
    inputs.ponygirls.homeManagerModules.service-postgres
    inputs.ponygirls.homeManagerModules.agenticServicesServer
    inputs.ponygirls.homeManagerModules.chronicleServer
  ];
}
