#!/bin/bash

set -euo pipefail

# Fix event filters
while read -r tekton_yaml
do
    # Build filter string
    if grep -q 'pull-request.yaml$' <<<"$tekton_yaml"
    then
        event="pull_request"
    elif grep -q 'push.yaml$' <<<"$tekton_yaml"
    then
        event="push"
    else
        echo "Error, can't determine event type for '$tekton_yaml'" >&2
        exit 1
    fi
    catalog_dir="$(yq -e e '.spec.params | .[] | select(.name == "path-context") | .value' "$tekton_yaml")"
    filter="event == \"$event\" && target_branch == \"main\" && ( \"$catalog_dir/***\".pathChanged() || \"$tekton_yaml\".pathChanged() )"
    export filter

    # Apply filter string
    yq -i e '.metadata.annotations."pipelinesascode.tekton.dev/on-cel-expression" = strenv(filter)' "$tekton_yaml"

    # Fix timeout
    if [[ "$event" == "pull_request" ]]
    then
        yq -i -e e '(.spec.params | .[] | select(.name == "image-expires-after") | .value) = "14d"' "$tekton_yaml"
    fi
done < <(find .tekton/ -type f -name '*.yaml')

# Task names to remove
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
