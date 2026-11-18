# A Profile: the same `export` lines as `mytokens env <service>`.
#   eval "$(op item get <title> --vault <v> --format json | jq -rj -L <dir> -f env.jq)"
include "mytokens";

if metadata.kind != "profile" then error("\(metadata.service)/\(metadata.account) is kind '\(metadata.kind)', not a Profile") else
  [fields
   | if .list then error("field '\(.label)' is a list: an environment variable cannot hold one")
     elif (.label | test("^[A-Za-z_][A-Za-z0-9_]*$") | not) then error("field '\(.label)' is not a valid environment-variable name")
     else "export \(.label)='\(.value | gsub("'"; "'\\''"))'\n" end]
  | add
end
