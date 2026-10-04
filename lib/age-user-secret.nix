# Look up an agenix secret for a Home Manager user.
# A user-scoped name ("<user>/<name>") wins over the host-scoped name.
{ secrets, user }: name:
  let
    userScopedName = "${user}/${name}";
  in
  if secrets ? ${userScopedName} then secrets.${userScopedName} else secrets.${name}
