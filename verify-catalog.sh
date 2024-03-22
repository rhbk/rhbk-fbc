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

# Skopeo is too slow and requires authentication, so use public Pyxis API.

# Query builder, has to be an actual script to work with xargs
cat > format-query.sh <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'repositories =em= (manifest_list_digest =in= (%s' "$1"
shift
if [ $# -gt 0 ]
then
    printf ',%s' "$@"
fi
printf '))\n'
EOF
chmod +x format-query.sh

# To avoid running into API limits, batch the image hashes into groups.
sed -r 's|^.*@([^@]+)$|\1|' images | sort -u > needed_hashes
cat needed_hashes | xargs -n30 ./format-query.sh > queries

echo "=> Checking customer portal"
# Execute the queries
while read -r query
do
    curl -sSf -X GET -G 'https://catalog.redhat.com/api/containers/v1/images' --data-urlencode "filter=$query" -H 'accept: application/json' | jq -r '.data | .[]? | .repositories | .[] | .manifest_list_digest'
done <queries > >(sort -u > found_hashes)

if grep -vxF -f found_hashes needed_hashes > missing_hashes
then
    echo "ERROR: One or more images in the catalog can not be found in customer portal" >&2
    grep -Ff missing_hashes images
    exit 11
fi

echo "=> Catalog OK!" >&2
