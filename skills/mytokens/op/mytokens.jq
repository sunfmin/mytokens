# Reads a mytokens Secret out of a 1Password vault item (`op item get <title> --vault <v> --format json`)
# on a machine without mytokens. The mapping is docs/adr/0022-1password-vault-as-a-sync-target.md.
# Used by secret.jq, env.jq and field.jq: run them with `jq -L <this directory>`.

def val: .value // "";

# The metadata section's fields as one object: service, account, kind, level, shape, order, meta.
def metadata: [.fields[]? | select(.section.label? == "mytokens") | {(.label): val}] | add // {};

# The Fields in order: [{label, list: bool, value}], a list Field's value the array of its records.
def fields:
  (metadata | .order | fromjson) as $order
  | [.fields[]? | select(.section == null and .purpose != "NOTES")] as $top
  | [.fields[]? | select(.section != null and .section.label != "mytokens")
       | (.section.label | capture("^(?<label>.*) \\[(?<i>[0-9]+)\\]$")) + {section: .section.label, key: .label, v: val}] as $cells
  | $order[] as $label
  | if any($cells[]; .label == $label) then
      {label: $label, list: true,
       value: [$cells | map(select(.label == $label)) | group_by(.section) | sort_by(.[0].i | tonumber)[]
               | map({(.key): .v}) | add]}
    else
      {label: $label, list: false, value: ([$top[] | select(.label == $label) | val] | first // "")}
    end;
