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

origin_dir="$(readlink -f .)"

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

# Configure bin directory as specified in the HEREDOC
while IFS=' ' read -r name version url_template
do
    # Download if required
    versioned_filename="$name-$version"
    if ! [ -x "$versioned_filename" ]
    then
        echo "-> Downloading $name" >&2
        url="$(eval echo "$url_template")"
        curl -sSfL --retry 5 -o "$versioned_filename" "$url"

        # Unpack zip if needed
        if grep -q '.zip$' <<<"$url"
        then
            unzip -qp "$versioned_filename" "$name" > "$versioned_filename.bin"
            mv "$versioned_filename.bin" "$versioned_filename"
        fi

        # Make executable
        chmod +x "$versioned_filename"
    fi

    # Set current version to active binary for this name
    ln -fs "$versioned_filename" "$name"
done <<'EOF'
kubectl v1.29.2 https://dl.k8s.io/release/$version/bin/$os/$arch/kubectl
kubelogin v1.28.0 https://github.com/int128/kubelogin/releases/download/$version/${name}_${os}_$arch.zip
yq v4.22.1 https://github.com/mikefarah/yq/releases/download/$version/yq_${os}_$arch
EOF

# Enable kubectl subcommand
ln -fs kubelogin kubectl-oidc_login

#
# Kubernetes
#

cd "$work_dir"

echo "=> Checking config" >&2

namespace="$(yq -e e '.konflux.namespace' "$cfg")"
prefix="$(yq -e e '.konflux.prefix' "$cfg")"
github="$(yq -e e '.konflux.github' "$cfg")"

kubectl_cfg="$(readlink -f konflux-kubectl-cfg.yaml)"
cat > "$kubectl_cfg" <<EOF
apiVersion: v1
clusters:
- cluster:
    server: https://api-toolchain-host-operator.apps.stone-prd-host1.wdlc.p1.openshiftapps.com/workspaces/$namespace
  name: appstudio
contexts:
- context:
    cluster: appstudio
    namespace: $namespace-tenant
    user: oidc
  name: appstudio
current-context: appstudio
kind: Config
preferences: {}
users:
- name: oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=https://sso.redhat.com/auth/realms/redhat-external
      - --oidc-client-id=rhoas-cli-prod
      command: kubectl
      env: null
      interactiveMode: IfAvailable
      provideClusterInfo: false
EOF

echo "=> Generating Konflux config for each catalog version" >&2
while read -r olm_dir
do
    olm_dir_relative="$(realpath --relative-to="$origin_dir" "$olm_dir")"

    olm_version="$(basename "$olm_dir")"
    echo "  -> $olm_version"
    mkdir "$olm_version"
    cd "$olm_version"

    # ex: v4.14 -> v4-14
    olm_version_dashed="$(tr '.' '-' <<<"$olm_version")"

    # Application (1 per Component due to Konflux release limitations)
    { cat <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Application
metadata:
  name: $namespace-$olm_version_dashed
  namespace: $namespace-tenant
spec:
  displayName: $namespace-$olm_version_dashed
EOF
    } > application.yaml

    # Component (1 per Application due to Konflux release limitations)
    { cat <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: $prefix-component-$olm_version_dashed
  namespace: $namespace-tenant
  annotations:
    image.redhat.com/generate: 'true'
spec:
  application: $namespace-$olm_version_dashed
  componentName: $prefix-component-$olm_version_dashed
  replicas: 0
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
  source:
    git:
      context: $olm_dir_relative/
      devfileUrl: >-
        https://raw.githubusercontent.com/$github/main/$olm_dir_relative/devfile.yaml
      dockerfileUrl: Dockerfile
      revision: main
      url: 'https://github.com/$github'
  targetPort: 50051
EOF
    } > component.yaml

    # IntegrationTestScenario (1 per Application)
    { cat <<EOF
apiVersion: appstudio.redhat.com/v1beta1
kind: IntegrationTestScenario
metadata:
  name: $namespace-$olm_version_dashed-enterprise-contract
  namespace: $namespace-tenant
  labels:
    test.appstudio.openshift.io/optional: 'false'
spec:
  application: $namespace-$olm_version_dashed
  contexts:
    - description: Application testing
      name: application
  params:
    - name: POLICY_CONFIGURATION
      value: $namespace-tenant/fbc-standard
  resolverRef:
    params:
      - name: url
        value: 'https://github.com/redhat-appstudio/build-definitions'
      - name: revision
        value: main
      - name: pathInRepo
        value: pipelines/enterprise-contract-redhat.yaml
    resolver: git
EOF
    } > integrationtestscenario.yaml

    cd ..
done < <(find "$origin_dir/catalog" -maxdepth 1 -type d -name 'v*')

echo "  -> fbc-standard" >&2
# EnterpriseContractPolicy (1 per namespace)
{ cat <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: EnterpriseContractPolicy
metadata:
  name: fbc-standard
  namespace: $namespace-tenant
spec:
  configuration:
    include:
      - '@redhat'
    exclude:
      # The release process separates the catalog from the binaries,
      # so CVEs are the responsibility of the OLM team
      - cve
      - step_image_registries
      # prefetch is not required
      - tasks.required_tasks_found:prefetch-dependencies
      # source containers are not required
      - tasks.required_tasks_found:source-build
      # summary being skipped due to missing task parameter from source build
      # since source builds are skipped
      - tasks.required_tasks_found:summary
  description: 'Includes rules for shipping Red Hat FBC fragments'
  publicKey: 'k8s://openshift-pipelines/public-key'
  sources:
    - name: Release Policies
      data:
        - github.com/release-engineering/rhtap-ec-policy//data
        - oci::quay.io/redhat-appstudio-tekton-catalog/data-acceptable-bundles:latest
      policy:
        - oci::quay.io/enterprise-contract/ec-release-policy:latest
EOF
} > enterprisecontractpolicy.yaml

#
# kubectl
#

work_dir_relative="$(realpath --relative-to="$origin_dir" "$work_dir")"
if [ -t 0 ]
then
    read -rn1 -p "Ok to apply YAMLs inside '$work_dir_relative' to Konflux? [y/N]: "
    echo ""
    if ! [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Aborting. No changes applied" >&2
        exit 2
    fi
else
    echo "Can't apply configs non-interactively, see $work_dir_relative" >&2
    exit 3
fi

echo "=> Your browser may open for authentication if required" >&2
echo "=> Applying Konflux config via kubectl" >&2
#kubectl --kubeconfig="$kubectl_cfg" apply -f TODO.yaml
