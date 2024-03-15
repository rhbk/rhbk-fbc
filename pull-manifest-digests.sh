#!/bin/bash

set -euo pipefail

# Update config.yaml will all currently published bundle images
cfg="config.yaml"
repository="$(yq -e e '.repository' "$cfg")"
url="https://catalog.redhat.com/api/containers/v1/repositories/registry/registry.access.redhat.com/repository/$repository/images"

# Remove any existing bundles first
yq -i e '.bundles = []' "$cfg"
while IFS=$'\t' read -r tag manifest_digest
do
    # Print the tags since they're much more human readable
    echo "$tag"
    DIGEST="$manifest_digest" yq -i e '.bundles += strenv(DIGEST)' "$cfg"
done < <(
    # Query customer catalog API and get the manifest digest for each tag of the bundle
    curl -sSf -X GET "$url" -H 'accept: application/json' \
        | jq -r '.data | .[]
            | .repositories | .[]
            | [(.tags | sort_by(.name | length) | .[-1].name), .manifest_list_digest]
            | @tsv' \
        | sort -V
)

echo "Done!" >&2
