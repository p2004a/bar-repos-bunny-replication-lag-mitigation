#!/bin/bash

set -euo pipefail

echo "Content-type: text/plain"
echo ""

# BUNNY_ACCESS_KEY=...
# BUNNY_STORAGE_ACCESS_KEY=...
PULL_ZONE_NAME="p2004a-bar-rapid"
STORAGE_ZONE_NAME="bar-rapid-ssd"
EDGE_RULE_DESC="Redirect to fresh version"

TMP_DIR="$(mktemp -d)"
echo "Workdir: $TMP_DIR"
cd "$TMP_DIR"
function cleanup {
  echo "Cleanup $TMP_DIR"
  rm -r "$TMP_DIR"
}
trap cleanup EXIT

curl --fail-with-body --silent \
     -L https://repos-cdn.beyondallreason.dev/byar/versions.gz \
     --output served_versions.gz
curl --silent -A 'curl latestreplicated' \
     -L https://repos-cdn.beyondallreason.dev/byar/versions.gz \
     --output latest_versions.gz

if [[ "$(md5sum served_versions.gz | cut -d ' ' -f 1)" == \
      "$(md5sum latest_versions.gz | cut -d ' ' -f 1)" ]]
then
  echo "Fresh, exiting"
  exit 0
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
  echo "Rule disabled, exiting"
fi

VER="$(date --utc "+%Y%m%dT%H%M%S")"
NEW_VERSIONS_PATH="byar/fresh/versions_$VER.gz"

curl --fail-with-body --silent --request PUT \
     --header "AccessKey: $BUNNY_STORAGE_ACCESS_KEY" \
     --header 'content-type: application/octet-stream' \
     --upload-file latest_versions.gz \
     --url "https://storage.bunnycdn.com/$STORAGE_ZONE_NAME/$NEW_VERSIONS_PATH" \
  | jq

BACKOFF=0.1
while ! curl --fail-with-body --silent --request GET \
             --url "https://repos-cdn.beyondallreason.dev/$NEW_VERSIONS_PATH" \
             --output /dev/null
do
  echo "not yet visible, retry after ${BACKOFF}s..."
  sleep $BACKOFF
  BACKOFF=$(jq -n "$BACKOFF * 2")
done

NEW_EDGE_RULE="$(
  jq <<< "$EDGE_RULE" ".ActionParameter1 = \"https://repos-cdn.beyondallreason.dev/$NEW_VERSIONS_PATH\""
)"

curl --fail-with-body --silent --request POST \
     --url "https://api.bunny.net/pullzone/$PULL_ZONE_ID/edgerules/addOrUpdate" \
     --header "AccessKey: $BUNNY_ACCESS_KEY" \
     --header 'content-type: application/json' \
     --data "$NEW_EDGE_RULE" \
  | jq
