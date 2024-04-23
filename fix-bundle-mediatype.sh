#!/bin/bash

set -euo pipefail

# For the catalog to function correctly in a multi-arch scenario, the
# referenced bundle digests must point to the correct kind of object. They must
# not be a:
#
#   application/vnd.docker.distribution.manifest.list.v2+json
#
# instead they must be a:
#
#   application/vnd.docker.distribution.manifest.v2+json
#
# IIB converts between the two by just picking the first manifest in the
# manifest list. This typically is the "x86" version of the bundle image, which
# is actually architecture independent (noarch) because the image contains only
# YAMLs. IIB's code is here:
#
# https://github.com/release-engineering/iib/blob/e5b5d715d8e1868234b8e71f0168a973596587a3/iib/workers/tasks/utils.py#L422-L462
#
# This script will ensure that the digests in config.yaml are manifests, not
# manifest lists.

cfg="config.yaml"

image_path="docker://$(yq e '.replacements[0].to' "$cfg")"

while read -r bundle_digest
do
    IFS=$'\t' read -r media_type zeroth_digest < <(skopeo inspect --raw "$image_path@$bundle_digest" | jq -r '[.mediaType, (.manifests | .[0]?.digest)] | @tsv')
    case $media_type in
        application/vnd.docker.distribution.manifest.list.v2+json)
            echo "Converting manifest list to manifest for bundle $bundle_digest" >&2
            B="$bundle_digest" D="$zeroth_digest" yq -i e '(.bundles[] | select(. == strenv(B))) = strenv(D)' "$cfg"
            ;;
        application/vnd.docker.distribution.manifest.v2+json)
            ;;
        *)
            echo "ERROR: unknown media type '$media_type' for bundle '$bundle_digest'" >&2
            exit 1
            ;;
    esac

done < <(yq e '.bundles[]' "$cfg")

echo "Done" >&2
