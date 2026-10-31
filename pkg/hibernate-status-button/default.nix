{ gnomeExtensions }:

# The catalog no longer includes Shell 48, the last declared version for v42.
# Keep the existing UUID/settings and the module's Shell compatibility policy.
gnomeExtensions.buildShellExtension {
  uuid = "hibernate-status@dromi";
  name = "Hibernate Status Button";
  pname = "hibernate-status-button";
  description = "Adds Hibernate and Hybrid Sleep options to the status menu";
  link = "https://extensions.gnome.org/extension/755/hibernate-status-button/";
  version = "42";
  sha256 = "03k3fabk72ipa60dssrdbijl2zjg332mci9cagdsy4jdlb41z2gw";
  metadata = "ewogICJfZ2VuZXJhdGVkIjogIkdlbmVyYXRlZCBieSBTd2VldFRvb3RoLCBkbyBub3QgZWRpdCIsCiAgImRlc2NyaXB0aW9uIjogIkFkZHMgYSBIaWJlcm5hdGUgYnV0dG9uIGluIFN0YXR1cyBtZW51LiBVc2luZyBBbHQgbW9kaWZpZXIsIHlvdSBjYW4gYWxzbyBzZWxlY3QgSHlicmlkIFNsZWVwIGluc3RlYWQuIiwKICAiZ2V0dGV4dC1kb21haW4iOiAiaGliZXJuYXRlLXN0YXR1cy1idXR0b24iLAogICJuYW1lIjogIkhpYmVybmF0ZSBTdGF0dXMgQnV0dG9uIiwKICAic2V0dGluZ3Mtc2NoZW1hIjogIm9yZy5nbm9tZS5zaGVsbC5leHRlbnNpb25zLmhpYmVybmF0ZS1zdGF0dXMtYnV0dG9uIiwKICAic2hlbGwtdmVyc2lvbiI6IFsKICAgICI0NSIsCiAgICAiNDYiLAogICAgIjQ3IiwKICAgICI0OCIKICBdLAogICJ1cmwiOiAiaHR0cHM6Ly9naXRodWIuY29tL2FyZWxhbmdlL2dub21lLXNoZWxsLWV4dGVuc2lvbi1oaWJlcm5hdGUtc3RhdHVzIiwKICAidXVpZCI6ICJoaWJlcm5hdGUtc3RhdHVzQGRyb21pIiwKICAidmVyc2lvbiI6IDQyCn0=";
}
