#!/bin/bash

set -euo pipefail

echo "Content-type: text/plain"
echo ""

# BUNNY_ACCESS_KEY=...
# BUNNY_STORAGE_ACCESS_KEY=...
# PULL_ZONE_NAME=...  # "p2004a-bar-rapid"
# STORAGE_ZONE_NAME=... # "bar-rapid-ssd"
# BASE_URL=...  # "https://repos-cdn.beyondallreason.dev"
# REPOS=...  # "byar byar-chobby"

TMP_DIR="$(mktemp -d)"
echo "Workdir: $TMP_DIR"
cd "$TMP_DIR"
function cleanup {
  echo "Cleanup $TMP_DIR"
  rm -r "$TMP_DIR"
}
trap cleanup EXIT

refresh_repo() {
  REPO=$1
  EDGE_RULE_DESC="Redirect to fresh $REPO version"

  curl --fail-with-body --silent \
       -L $BASE_URL/$REPO/versions.gz \
       --output served_${REPO}_versions.gz
  curl --silent -A 'curl latestreplicated' \
       -L $BASE_URL/$REPO/versions.gz \
       --output latest_${REPO}_versions.gz

  if [[ "$(md5sum served_${REPO}_versions.gz | cut -d ' ' -f 1)" == \
        "$(md5sum latest_${REPO}_versions.gz | cut -d ' ' -f 1)" ]]
  then
    echo "$REPO is fresh"
    return
  fi

  PULL_ZONE="$(
    curl --fail-with-body --silent --request GET \
         --url "https://api.bunny.net/pullzone?includeCertificate=false" \
         --header "AccessKey: $BUNNY_ACCESS_KEY" \
         --header 'accept: application/json' \
      | jq -e ".[] | select(.Name == \"$PULL_ZONE_NAME\")"
  )"
  PULL_ZONE_ID="$(jq <<< "$PULL_ZONE" -e ".Id")"

  EDGE_RULE="$(
    jq <<< "$PULL_ZONE" -e ".EdgeRules[] | select(.Description == \"$EDGE_RULE_DESC\")"
  )"

  if [[ "$(jq <<< "$EDGE_RULE" '.Enabled')" != "true" ]]
  then
    echo "$REPO rule disabled, exiting"
    return
  fi

  VER="$(date --utc "+%Y%m%dT%H%M%S")"
  NEW_VERSIONS_PATH="$REPO/fresh/versions_$VER.gz"

  curl --fail-with-body --silent --request PUT \
       --header "AccessKey: $BUNNY_STORAGE_ACCESS_KEY" \
       --header 'content-type: application/octet-stream' \
       --upload-file latest_${REPO}_versions.gz \
       --url "https://storage.bunnycdn.com/$STORAGE_ZONE_NAME/$NEW_VERSIONS_PATH" \
    | jq

  BACKOFF=0.1
  while ! curl --fail-with-body --silent --request GET \
               --url "$BASE_URL/$NEW_VERSIONS_PATH" \
               --output /dev/null
  do
    echo "not yet visible, retry after ${BACKOFF}s..."
    sleep $BACKOFF
    BACKOFF=$(jq -n "$BACKOFF * 2")
  done

  NEW_EDGE_RULE="$(
    jq <<< "$EDGE_RULE" ".ActionParameter1 = \"$BASE_URL/$NEW_VERSIONS_PATH\""
  )"

  curl --fail-with-body --silent --request POST \
       --url "https://api.bunny.net/pullzone/$PULL_ZONE_ID/edgerules/addOrUpdate" \
       --header "AccessKey: $BUNNY_ACCESS_KEY" \
       --header 'content-type: application/json' \
       --data "$NEW_EDGE_RULE" \
    | jq
}

for repo in $REPOS
do
  refresh_repo $repo
done
