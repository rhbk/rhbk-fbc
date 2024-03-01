#!/bin/bash

set -euo pipefail

#
# Setup
#

if ! cfg="$(readlink -e config.yaml)"
then
    echo "Could not find config file $cfg" >&2
    exit 1
fi

echo "=> Setting up" >&2

# Save starting dir as the place to put the catalog files
catalog_dir="$(readlink -e .)"

# We need a few binaries at specific versions, so create a local cache for those
bin_dir="$(readlink -f bin)"
mkdir -p "$bin_dir"
export PATH="$bin_dir:$PATH"

# There will be some temporary files, put these together for neatness, and so
# they can be easily deleted.
work_dir="$(readlink -f workdir)"
rm -rf "$work_dir"
mkdir "$work_dir"

# Acquire any missing binaries
cd "$bin_dir"

# Being binaries, they're OS and Arch specific
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/')"

# These are the specific versions we want
opm_version="v1.36.0"
yq_version="v4.22.1"
tf_version="v0.1.0"

# Store them first into a versioned filename so the bin dir never gets stale if
# the required versions change.
opm_filename="opm-$opm_version"
yq_filename="yq-$yq_version"
tf_filename="tf-$tf_version"

if ! [ -x "$opm_filename" ]
then
    echo "-> Downloading opm" >&2
    curl -sSfLo "$opm_filename" "https://github.com/operator-framework/operator-registry/releases/download/$opm_version/$os-$arch-opm"
    chmod +x "$opm_filename"
fi
ln -fs "$opm_filename" opm

if ! [ -x "$yq_filename" ]
then
    echo "-> Downloading yq" >&2
    curl -sSfLo "$yq_filename" "https://github.com/mikefarah/yq/releases/download/$yq_version/yq_${os}_$arch"
    chmod +x "$yq_filename"
fi
ln -fs "$yq_filename" yq

# tap-fitter doesn't have binary downloads at the moment, so assume golang is
# available and use that to install.
if ! [ -x "$tf_filename" ]
then
    echo "-> Downloading tap-fitter" >&2
    GOBIN="$bin_dir" go install "github.com/release-engineering/tap-fitter/cmd/tap-fitter@$tf_version"
    mv tap-fitter "$tf_filename"
fi
ln -fs "$tf_filename" tap-fitter

#
# Generate Config YAMLs
#

cd "$work_dir"

echo "=> Checking config" >&2

# Should be equal to .spec.name from the bundle CSVs
operator_name="$(yq -e ea '.name' "$cfg")"

# Assume the replacement with "bundle" in the name is the one we need to prefix
# onto the bundle hashes listed in the config YAML.
IFS=$'\t' read -r bundle_reg_from bundle_reg_to < <(yq -e -o tsv ea '.replacements[] | select(.from == "*bundle*") | [.from, .to]' "$cfg")

# opm will need to access the images in this registry to do its work
# https://source.redhat.com/groups/public/teamnado/wiki/brew_registry#obtaining-registry-tokens
if ! podman login --get-login "$bundle_reg_from" >/dev/null
then
    echo "Login to $(cut -f1 -d/ <<<"$bundle_reg_from") before running this script" >&2
    exit 125
fi

readarray -t ocp_versions < <(yq -e ea '.ocp[]' "$cfg")

echo "=> Generating catalog configuration" >&2

echo "-> Applying bundle image list" >&2
render_config="semver-template.yaml"
{
    # Write intial config values
    cat <<EOF
schema: olm.semver
generatemajorchannels: true
generateminorchannels: false
stable:
  bundles:
EOF
    # Append the bundle image coordinates.
    # We're using an initial "from" registry and switching it later because opm
    # can't be configured with a mirror replacement policy, and some of these
    # bundle images may currently be only present in the "from" registry, not
    # the public "to" registry.
    yq -e ea '.bundles | .[]' "$cfg" | xargs -n1 printf '    - image: %s@%s\n' "$bundle_reg_from"
} > "$render_config"

echo "-> Defining supported OCP versions" >&2
{
    # Preamble
    cat <<EOF
schema: olm.composite
components:
EOF
    # One component entry per OCP version supported
    for olm_version in "${ocp_versions[@]}"
    do
        cat <<EOF
  - name: $olm_version
    destination:
      path: $operator_name
    strategy:
      name: semver
      template:
        schema: olm.builder.semver
        config:
          input: $render_config
          output: catalog.yaml
EOF
    done
} > contributions.yaml

{
    # Preamble
    cat <<EOF
schema: olm.composite.catalogs
catalogs:
EOF
    # One catalog per OCP version supported
    for olm_version in "${ocp_versions[@]}"
    do
        cat <<EOF
- name: $olm_version
  destination:
    workingDir: catalog/$olm_version
  builders:
    - olm.builder.semver
EOF
    done
} > catalogs.yaml

#
# Generate Catalog
#

echo "=> Generating catalog for $operator_name" >&2

echo "-> opm render" >&2
opm alpha render-template composite -f catalogs.yaml -c contributions.yaml

echo "-> tap-fitter" >&2
tap-fitter --catalog-path catalogs.yaml --composite-path contributions.yaml --provider "$operator_name"

echo "-> Dockerfiles + devfiles" >&2
for ocp_ver in "${ocp_versions[@]}"
do
    # Soon this might be able to be simplified, as "binaryless" container, FROM scratch
    cat > "catalog/$ocp_ver/Dockerfile" <<EOF
# The base image is expected to contain
# /bin/opm (with a serve subcommand) and /bin/grpc_health_probe
FROM registry.redhat.io/openshift4/ose-operator-registry:$ocp_ver

# Configure the entrypoint and command
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

# Copy declarative config root into image at /configs and pre-populate serve cache
ADD $operator_name /configs/$operator_name
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

# Set DC-specific label for the location of the DC root directory
# in the image
LABEL operators.operatorframework.io.index.configs.v1=/configs
EOF

    devfile="catalog/$ocp_ver/devfile.yaml"
    yq -i e '.metadata.name = "fbc-" + .metadata.name' "$devfile"
    yq -i e '.metadata.displayName = "FBC " + .metadata.displayName' "$devfile"
    yq -i e '.metadata.provider = "Red Hat"' "$devfile"
    yq -i e 'with(.components | .[] | select(.name == "image-build") ;
                .image.imageName = "" |
                .image.dockerfile.uri = "Dockerfile" |
                .image.dockerfile.buildContext = ""
            )' "$devfile"
    yq -i e '.components += {"name": "kubernetes"}' "$devfile"
    yq -i e 'with(.components | .[] | select(.name == "kubernetes") ;
                .kubernetes.inlined = "placeholder" |
                .attributes."deployment/container-port" = 50051 |
                .attributes."deployment/cpuRequest" = "100m" |
                .attributes."deployment/memoryRequest" = "512Mi" |
                .attributes."deployment/replicas" = 1 |
                .attributes."deployment/storageRequest" = "0"
            )' "$devfile"
done

echo "-> Replacing registries" >&2
# This step is required because opm doesn't support registry mirrors, and must
# be able to see the images, so we have to give it the stage registry to work
# with, and then replace the coordinates so they are valid public ones.
while IFS=$'\t' read -r reg_from reg_to
do
    find catalog -type f | xargs sed -i "s|$reg_from|$reg_to|g"
done < <(yq -e -o tsv ea '.replacements[] | [.from, .to]' "$cfg")

echo "-> Copying generated files" >&2
rm -rf "$catalog_dir/catalog"
cp -r "catalog" "$catalog_dir"

{
    echo ""
    echo "Catalog generated OK!"
} >&2
