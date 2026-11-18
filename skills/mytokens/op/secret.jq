# The whole Secret: the same JSON as `mytokens get <service> --json`.
#   op item get <title> --vault <v> --format json | jq -cSj -L <dir> -f secret.jq
include "mytokens";

metadata as $m
| if $m.shape == "bare"
  then {level: $m.level, value: ([fields][0].value)}
  else {level: $m.level, fields: ([fields] | map({(.label): .value}) | add)}
  end
