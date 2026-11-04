#!/bin/sh
# Build phase of the watch app (project.yml preBuildScripts). A Release build, the one that is archived and uploaded,
# stops when the connector key is empty or still the example placeholder: Secrets.xcconfig is an optional include, so a
# fresh clone would otherwise archive and upload a build that only fails on the watch. Debug builds pass with no key,
# so simulator runs against the local stub (-devTokenFile) still build. Never prints the key.
if [ "${CONFIGURATION}" != "Release" ]; then exit 0; fi
key=$(printf '%s' "${COACH_API_TOKEN}" | tr -d '[:space:]')
if [ -z "${key}" ] || [ "${key}" = "paste-synthetic-key-here" ]; then
  echo "error: COACH_API_TOKEN is empty or the example placeholder. Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig and paste the synthetic test key before archiving."
  exit 1
fi
exit 0
