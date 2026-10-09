# Helpers for resolving agenix secrets for a Home Manager user.
# A user-scoped name ("<user>/<name>") wins over the host-scoped name.
let
  resolveName = { secrets, user }: name:
    let
      userScopedName = "${user}/${name}";
    in
    if secrets ? ${userScopedName} then userScopedName else name;
in
{
  # The secret itself; throws when neither name variant is present.
  ageUserSecret = { secrets, user }@args: name: secrets.${resolveName args name};

  # Whether the secret is present under either name variant.
  ageUserSecretExists = { secrets, user }@args: name: secrets ? ${resolveName args name};
}
