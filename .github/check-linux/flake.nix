{
  outputs = _: let
    inherit (builtins.fromJSON (builtins.readFile ./partition.json)) project isolated selected;
    root = (builtins.getFlake project).outputs;
    linux = root.checks.x86_64-linux;
  in
    assert builtins.all (name: builtins.hasAttr name linux) isolated;
    if root ? schemas.checks then
      throw "Cannot partition a custom checks schema; review the Linux CI partitions."
    else if selected == "" then
      root // {
        checks = root.checks // { x86_64-linux = builtins.removeAttrs linux isolated; };
      }
    else
      assert builtins.elem selected isolated;
      { checks.x86_64-linux.${selected} = linux.${selected}; };
}
