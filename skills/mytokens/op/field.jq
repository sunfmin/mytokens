# One Field: a text Field's value as is, a list Field as the JSON array of its records, the
# same as `mytokens get <service> --field <Label>`.
#   op item get <title> --vault <v> --format json | jq -cSj -L <dir> --arg label <Label> -f field.jq
include "mytokens";

([fields | select(.label == $label)] | first) as $f
| if $f == null then error("no field '\($label)'") else $f.value end
