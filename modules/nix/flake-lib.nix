{ config, lib, ... }:
let
  assertHasAttr =
    { source, base, name, msg, test }:
    let
      path = lib.splitString "." base;
      baseAttrSet = lib.attrsets.getAttrFromPath path config;
    in
    {
      assertion =
        builtins.hasAttr name baseAttrSet && test baseAttrSet."${name}";
      message = "(${source}) ${base}.${name}: ${msg}";
    };
  assertHasStringAttr = input: assertHasAttr (input // { test = a: builtins.isString a && a != ""; });
in
{
  _module.args.assertHasStringAttr = assertHasStringAttr;
  _module.args.assertHasAttr = assertHasAttr;
}
