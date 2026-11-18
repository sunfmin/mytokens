# Issue tracker: factorium

Issues for this repo live in factorium's local tracker on the host. `<checkout>` is this
repo's name in `factorium checkout list` (`mytokens`).

- **Create**: `factorium issue add <checkout> <title> --body-file - [--blocked-by <n> …]`
- **List / read**: `factorium issue list <checkout>` / `factorium issue show <checkout> <n>`
- **Comment**: `factorium issue comment <checkout> <n> …`
- **Blocking**: `factorium issue block <checkout> <n> …`, or `--blocked-by` at creation.

There are no labels. GitHub issues and external PRs are not a request surface.

## When a skill says "publish to the issue tracker"

Create an issue as above.

## When a skill says "fetch the relevant ticket"

`factorium issue show <checkout> <n>`.
