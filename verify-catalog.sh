#!/bin/bash

set -euo pipefail

orig_dir="$(readlink -f .)"
work_dir="$(readlink -f workdir)"
rm -rf "$work_dir"
mkdir "$work_dir"
cd "$work_dir"

# Collect all unique image references in catalog
find "$orig_dir/catalog/" -type f -name '*.yaml' | \
    xargs yq e '.relatedImages | .[] | .image' | \
    grep -v '^---' | \
    sort -Vu \
    > images

echo "=> Catalog contains $(wc -l images | cut -d' ' -f1) unique images" >&2

# Only allow registry.redhat.io images
if sed -r 's|^([^/]+)/.*$|\1|;tx;d;:x' images | sort -u | grep -v 'registry.redhat.io' > invalid-registries
then
    echo "ERROR: Invalid registries found:" >&2
    cat invalid-registries >&2
    exit 10
fi

echo "=> Checking registry auth" >&2
for check_registry in "registry.redhat.io" "brew.registry.redhat.io"
do
    if ! skopeo login --get-login "$check_registry" >/dev/null 2>/dev/null
    then
        if [ -v "RH_REGISTRY_USERNAME" ] && [ -v "RH_REGISTRY_PASSWORD" ]
        then
            skopeo login --username "$RH_REGISTRY_USERNAME" --password-stdin "$check_registry" <<<"$RH_REGISTRY_PASSWORD"
        else
            echo "Login to $check_registry before running this script" >&2
            exit 125
        fi
    fi
done

# Cache since skopeo is slow
cache="$orig_dir/verified_coordinates"
if [ -f "$cache" ]
then
    echo "=> Loading cache" >&2
    cp "$cache" found
else
    >found
fi

echo "=> Checking images" >&2
error=""
>invalid-mediatype
>image-missing
>image-found-in-brew
while read -r image
do
    if grep -qxF -e "$image" found
    then
        continue
    fi
    echo " -> $image" >&2

    if mediatype="$(skopeo inspect --raw "docker://$image" | jq -r '.mediaType')"
    then
        # Image found, but ensure mediatype of bundles is ok
        if grep -qF -e '-bundle@' <<<"$image" && [ "$mediatype" != "application/vnd.docker.distribution.manifest.v2+json" ]
        then
            echo "$image $mediatype" >> invalid-mediatype
        else
            echo "$image" >> found
        fi
    else
        # Image not found
        echo "$image" >> image-missing

        # Check brew to see if it's there
        if skopeo inspect --raw "docker://brew.$image"
        then
            echo "$image" >> image-found-in-brew
        fi
    fi
done <images

if [ -s invalid-mediatype ]
then
    echo "" >&2
    echo "ERROR: one or more bundle digests points at an invalid mediatype:" >&2
    cat invalid-mediatype >&2
    error="20"
fi

if [ -s image-missing ]
then
    echo "" >&2
    echo "ERROR: one or more images can not be found in registry.redhat.io:"
    cat image-missing >&2
    error="21"
    if [ -s image-found-in-brew ]
    then
        echo "" >&2
        echo "These images however were found in Brew, pending release:" >&2
        cat image-found-in-brew >&2
    fi
fi

if [ -n "$error" ]
then
    exit "$error"
fi

# Save cache if all is well
cp found "$cache"

echo "=> Catalog OK!" >&2
