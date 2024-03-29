#!/bin/bash

# Update and install packages using apk on Alpine Linux
if command -v apk &> /dev/null; then
  apk update && apk add jq curl

# Update and install packages using yum on CentOS
elif command -v yum &> /dev/null; then
  yum update && yum install jq curl

# Update and install packages using apt on Debian-based systems
elif command -v apt-get &> /dev/null; then
  apt update && apt install jq curl

# If none of the package managers are found
else
  echo "Unsupported package manager. Please install jq and curl before run this orb."
fi

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

# Allow some time for other pipelines to run before fetching the list of pipeline IDs
sleep 2

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
  PIPE_LIST=$(echo "$PIPE_IDS" | tr " " "\n")  # Convert space separated values into array
  echo "The last 5 pipelines :"
  # # ideally we only need to take 1 element after the first one, since it's the immediate previous build and we want to cancel that
  # # but we loop several pipelines (5) just in case some are still running, so that we can cancel it here
  # # Limited it to 5 to save on the number of API calls
  i=0
  for PIPE_ID in $PIPE_LIST
  do
    if [ "$i" -eq 0 ]; then
      if [ "${#PIPE_LIST[@]}" -eq 1 ]; then
        exit
      fi
      i=$((i + 1))
      continue
    fi
    if [ "$i" -lt 6 ]; then
      echo "${PIPE_ID}"
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
      i=$((i + 1))
    else
      break
    fi
  done
fi

## Cancel any currently running/on_hold workflow with the same name
if [ -s WF_to_cancel.txt ]; then
  echo "Canceling the following workflow(s):"
  cat WF_to_cancel.txt
  while read -r WF_ID;
    do
      echo "Canceling ${WF_ID}"
      curl --header "Circle-Token: $CIRCLE_API_KEY" --request POST https://circleci.com/api/v2/workflow/"$WF_ID"/cancel
    done < WF_to_cancel.txt
  ## Allowing some time to complete the cancellation
  sleep 2
  else
    echo "Nothing to cancel"
fi

rm -f WF_to_cancel.txt
