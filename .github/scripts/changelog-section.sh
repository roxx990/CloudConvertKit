#!/bin/bash
#  Prints the body of a version's section of CHANGELOG.md (from its
#  `## <version>` heading to the next `## ` heading), the notes of that
#  version's GitHub release. Fails when the section is missing or empty.
#
#  With a base URL, relative links (`[License](LICENSE)`) become links
#  under it, as release notes aren't rendered relative to the repository.
#
#  Usage: .github/scripts/changelog-section.sh 2.0.0
#         .github/scripts/changelog-section.sh 2.0.0 https://github.com/owner/repo/blob/2.0.0

set -euo pipefail

version="${1:?usage: $0 <version> [base URL]}"
base="${2:-}"
changelog="$(cd "$(dirname "$0")/../.." && pwd)/CHANGELOG.md"

notes="$(awk -v heading="## $version" '
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$changelog" | sed -e '/./,$!d')"  # leading blank lines; $(…) drops trailing ones

if [ -z "$notes" ]; then
    echo "CHANGELOG.md has no section for $version (a \`## $version\` heading)." >&2
    exit 1
fi
if [ -n "$base" ]; then
    # A link target with no scheme (no colon) and not an anchor is a path.
    notes="$(printf '%s\n' "$notes" | sed -E "s|\]\(([^)#:][^):]*)\)|](${base%/}/\1)|g")"
fi
printf '%s\n' "$notes"
