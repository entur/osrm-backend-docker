#!/usr/bin/env bash
#
# Pre-build the OSRM graph into a NEW GCS prefix WITHOUT touching the live
# deployments. Use this before deploying a new osrm-backend major (a "build-then-flip"
# cutover) so the new pods find their data immediately.
#
# Why this exists: an OSRM major bump changes the version-locked graph format AND (for
# tst/prd) performs the water->ferry rename in the same deploy. If the new pods start
# on an empty prefix they CrashLoopBackOff; for the renamed ferry/water Service that is
# an actual outage (the Service flips to the not-yet-ready ferry pods). Pre-populating
# the new prefix first avoids that: the new pods come up healthy on data that already
# exists. See the "Upgrading the OSRM version" runbook in README.md.
#
# It runs, per profile, the same pipeline as the redeploy CronJob's init containers
# (download OSM -> osrm-extract -> osrm-contract -> gsutil upload) but with NO redeploy
# step, so the running (old) deployments keep serving untouched while this builds.
#
# Usage:
#   ./prebuild-osrm-graph.sh <dev|tst|prd> <prefix> <image-tag>
#
# Example (prepare tst for v26 with the exact image you're about to deploy):
#   ./prebuild-osrm-graph.sh tst v26 rutebanken.20260731-SHA6b34719
#
# IMPORTANT: <image-tag> MUST be the same osrm-api image you will deploy. The graph
# format is version-locked, so pre-building with one v26 build and deploying a different
# major/incompatible build would still crashloop. Pin the deploy to this image, or run
# this immediately before the deploy with the current image.
#
set -euo pipefail

ENV="${1:?usage: $0 <dev|tst|prd> <prefix> <image-tag>}"
PREFIX="${2:?usage: $0 <dev|tst|prd> <prefix> <image-tag>   (e.g. v26)}"
IMAGE_TAG="${3:?usage: $0 <dev|tst|prd> <prefix> <image-tag>   (e.g. rutebanken.20260731-SHA6b34719)}"

IMAGE="eu.gcr.io/entur-system-1287/osrm-api:${IMAGE_TAG}"
OSM_URL="https://storage.googleapis.com/ror-osmdata-prd/osm-data/merged-latest.osm.pbf"

case "$ENV" in
  dev) CTX=gke_ent-kub-dev_europe-west1_kub-ent-dev-001; BUCKET=ror-osrm-internal-dev ;;
  tst) CTX=gke_ent-kub-tst_europe-west1_kub-ent-tst-001; BUCKET=ror-osrm-internal-tst ;;
  prd) CTX=gke_ent-kub-prd_europe-west1_kub-ent-prd-001; BUCKET=ror-osrm-internal-prd ;;
  *) echo "unknown env: $ENV (expected dev|tst|prd)" >&2; exit 1 ;;
esac

# profile-lua : service-name (upload path suffix). ferry data is served under "water".
PROFILES=( "bus:bus" "rail:rail" "ferry:water" )

echo "Pre-building osrm graph  env=$ENV  prefix=$PREFIX  image=$IMAGE"
echo "  context = $CTX"
echo "  bucket  = gs://$BUCKET/$PREFIX/"
echo

for entry in "${PROFILES[@]}"; do
  PROFILE="${entry%%:*}"; SVC="${entry##*:}"
  JOB="osrm-${SVC}-prebuild-${PREFIX}"
  echo ">>> $PROFILE -> gs://${BUCKET}/${PREFIX}/osrm-${SVC}/   (job: $JOB)"
  kubectl --context "$CTX" -n osrm delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
  cat <<YAML | kubectl --context "$CTX" -n osrm apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: osrm
  labels:
    app: osrm-prebuild
    team: ror
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app: osrm-prebuild
    spec:
      restartPolicy: Never
      serviceAccountName: application
      securityContext:
        runAsGroup: 1000
        runAsNonRoot: true
        runAsUser: 1000
      volumes:
        - name: osm-data
          emptyDir:
            sizeLimit: 10Gi
      initContainers:
        - name: download-osm-data
          image: curlimages/curl:8.12.1
          command: ['sh', '-c', 'curl -fSL -o /data/norway-latest.osm.pbf ${OSM_URL}']
          volumeMounts: [{ mountPath: /data, name: osm-data }]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
        - name: osrm-extract
          image: ${IMAGE}
          command: ['osrm-extract', '-p', '/opt/${PROFILE}.lua', '/data/norway-latest.osm.pbf']
          resources:
            limits: { memory: 16000Mi }
            requests: { cpu: 6, memory: 14000Mi }
          volumeMounts: [{ mountPath: /data, name: osm-data }]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
        - name: osrm-contract
          image: ${IMAGE}
          command: ['osrm-contract', '/data/norway-latest.osrm']
          resources:
            limits: { memory: 16000Mi }
            requests: { cpu: 6, memory: 14000Mi }
          volumeMounts: [{ mountPath: /data, name: osm-data }]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
        - name: upload-osrm-data
          image: google/cloud-sdk:537.0.0
          command:
            - sh
            - -c
            - 'gsutil -o GSUtil:parallel_composite_upload_threshold=150M -q -m rsync -d -r -x "^(?!.*norway-latest.osrm\.).*" /data gs://${BUCKET}/${PREFIX}/osrm-${SVC}/'
          env: [{ name: CLOUDSDK_CORE_DISABLE_PROMPTS, value: "1" }]
          volumeMounts: [{ mountPath: /data, name: osm-data }]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: done
          image: google/cloud-sdk:537.0.0
          command: ['sh', '-c', 'echo "prebuild complete: gs://${BUCKET}/${PREFIX}/osrm-${SVC}/"']
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
YAML
done

echo
echo "Jobs created. Watch progress:"
echo "  kubectl --context $CTX -n osrm get jobs -l app=osrm-prebuild -w"
echo
echo "When all show Complete, verify the data landed:"
for entry in "${PROFILES[@]}"; do SVC="${entry##*:}"
  echo "  gsutil ls gs://${BUCKET}/${PREFIX}/osrm-${SVC}/ | head"
done
echo
echo "Only after all three prefixes are populated, deploy the ${IMAGE_TAG} chart"
echo "(osrmVersion=${PREFIX}) to $ENV."
