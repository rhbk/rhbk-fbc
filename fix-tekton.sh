#!/bin/bash

set -euo pipefail

remove=(
    clair-scan
    clamav-scan
    prefetch-dependencies
    sast-snyk-check
    ecosystem-cert-preflight-checks
)

# Delete the given tasks that shouldn't be there
task_pattern="$(printf '.name == "%s" or ' "${remove[@]}" | sed 's/ or $//')"
find .tekton/ -type f -name '*.yaml' | xargs -n1 yq -i e "del(.spec.pipelineSpec.tasks | .[] | select($task_pattern))"

# Delete any dependency on the removed tasks
dep_pattern="$(printf '. == "%s" or ' "${remove[@]}" | sed 's/ or $//')"
find .tekton/ -type f -name '*.yaml' | xargs -n1 yq -i e "del(.spec.pipelineSpec.tasks | .[] | .runAfter | .[] | select($dep_pattern))"
