#!/bin/bash

if [ "$CIRCLE_BRANCH" != "$DEFAULT_BRANCH" ]; then
  echo 'Not on default branch, no need to manually cancel duplicate workflow'
  exit
fi

CIRCLE_API_KEY=$(eval echo "$CIRCLE_API_KEY")

# Get the name of the workflows in the pipeline
WF_NAMES=$(curl --header "Circle-Token: $CIRCLE_API_KEY" --request GET \
  "https://circleci.com/api/v2/pipeline/${PIPELINE_ID}/workflow" | jq -r '.items[].name')

echo "Workflow(s) in pipeline:"
echo "$WF_NAMES"

## Get the IDs of pipelines created with the the current CIRCLE_SHA1
PIPE_API_RES=$(curl --header "Circle-Token: $CIRCLE_API_KEY" --request GET \
  "https://circleci.com/api/v2/project/gh/$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME/pipeline?branch=$CIRCLE_BRANCH")

if [ "$SKIP_ALL_PREVIOUS" = 1 ] ; then
  PIPE_IDS=$(echo "$PIPE_API_RES" | jq -r \
  ' .items[]|select(.state == "created").id')
else
  PIPE_IDS=$(echo "$PIPE_API_RES" | jq -r --arg CIRCLE_SHA1 "${CIRCLE_SHA1}" \
  ' .items[]|select(.state == "created" and .vcs.revision == $CIRCLE_SHA1).id')
fi

# CircleCI API will return at most 15 latest pipeline IDs
echo "Pipeline IDs:"
echo "$PIPE_IDS"

## Get the IDs of currently running/on_hold workflows with the same name except the current workflow ID
if [ -n "$PIPE_IDS" ]; then
  mapfile -t PIPE_LIST <<< "$PIPE_IDS" # Convert space separated values into array

  # ideally we only need to take 1 element after the first one, since it's the immediate previous build and we want to cancel that
  # but we loop several pipelines (5) just in case some are still running, so that we can cancel it here
  for PIPE_ID in "${PIPE_LIST[@]:1:5}"
  do
    result=$(curl --header "Circle-Token: $CIRCLE_API_KEY" --request GET "https://circleci.com/api/v2/pipeline/${PIPE_ID}/workflow")

    # Cancel every workflow
    for WF_NAME in $WF_NAMES
    do
      echo "$result" \
      | jq -r \
        --arg PIPELINE_ID "${PIPELINE_ID}" \
        --arg WF_NAME "${WF_NAME}" \
        '.items[]|select(.status == "on_hold" or .status == "running")|select(.name == $WF_NAME)|select(.pipeline_id != $PIPELINE_ID)|.id' \
        >> WF_to_cancel.txt
    done
  done
fi

## Cancel any currently running/on_hold workflow with the same name
if [ -s WF_to_cancel.txt ]; then
  echo "Canceling the following workflow(s):"
  cat WF_to_cancel.txt 
  while read -r WF_ID;
    do
      curl --header "Circle-Token: $CIRCLE_API_KEY" --request POST https://circleci.com/api/v2/workflow/"$WF_ID"/cancel
    done < WF_to_cancel.txt
  ## Allowing some time to complete the cancellation
  sleep 2
  else
    echo "Nothing to cancel"
fi

rm -f WF_to_cancel.txt