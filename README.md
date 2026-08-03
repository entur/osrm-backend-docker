# OSRM API

This project uses the [osrm-backend](https://github.com/Project-OSRM/osrm-backend)
Open Source Routing Machine (OSRM) [Docker Image](https://github.com/project-osrm/osrm-backend/pkgs/container/osrm-backend)

## Profiles

The `profiles` folder contains custom profile code that is copied into the docker image. That is
the only addition to the upstream image. See `profiles/README.md` from more information.

## Architecture

### Docker build

This project builds a custom docker image with the upstream osrm-backend image as a base
and copies the custom profiles into it as mentioned above. This custom image is then used
in both the CronJobs (for building the osrm data) and for the main deployments.

### Data pipeline and redeploy

This project uses Kubernetes CronJobs with init containers to build the OSRM data / graph. The
job ends with a redeployment of the main services.

There are three CronJobs, each corresponding to a main deployment servicing a specific profile: 

- bus
- rail
- water (ferry)

Each CronJob runs the following init containers in sequence:

1. Download OSM data (protobuf file) from a GCP bucket
2. Run osrm-extract (with our custom docker image) with a specific profile and the OSM data as input
3. Run osrm-contract (with our custom docker image) on the output of the previous step
4. Copy the output (osrm data) to a GCP bucket

The main contanier of the CronJob then finishes the pipeline by triggering a redeploy
of the main service.

### Main routing service (deployment)

The main deployment has its own init container which downloads the osrm data uploaded by
step 4 in the CronJob pipeline as described above.

The main container then simply runs `osrm-routed`  (with our custom docker image) 
with the downloaded data as input.

### Upgrading the OSRM version

**An OSRM version bump is always two coupled actions: a new image _and_ a graph rebuild.**
OSRM's pre-processed graph files (`*.osrm.*`) are version-locked. A newer `osrm-routed`
refuses to load data prepared by an older `osrm-extract`/`osrm-contract` (and vice versa),
failing with:

```
File is incompatible with this version of OSRM:
/data/norway-latest.osrm.ebg_nodes prepared with OSRM <old> but this is <new>
```

So bumping the base image in the `Dockerfile` alone will **wedge the rollout**: the new
`osrm-routed` pods CrashLoopBackOff on the still-old graph data, the deployment can't retire
the old (healthy) pods, and it never converges.

Note that `data.osrmVersion` in the Helm values is **not** the OSRM software version — it is
only the GCS path prefix (`gs://<bucket>/<osrmVersion>/osrm-<profile>/`) used by both the
CronJob upload and the deployment download. Bumping it alone does **not** rebuild data; it
just points both sides at a (possibly empty) new path.

Recommended procedure, rolled out one environment at a time (dev → tst → prd):

1. Merge the base-image bump together with a bump of `data.osrmVersion` to a fresh prefix
   (e.g. `v6` → `v26`). Using a *new* prefix keeps the old graph data intact at the old
   prefix, which is what makes rollback possible. Include any profile fixes the new engine
   needs — a new engine can add Lua profile properties; run `./run-test.sh` first to catch
   extract crashes. CD builds the new image and deploys the new engine + prefix.
2. On deploy the new `osrm-routed` pods CrashLoopBackOff, because the new prefix is still
   empty. **This is expected and causes no outage:** the rollout never converges, so the old
   ReplicaSet keeps serving. The old pods are unaffected — they still read the old prefix.
3. **While the rollout is retrying**, trigger each profile's (suspended) build CronJob to
   populate the new prefix. Each runs extract → contract → upload → redeploy:

   ```bash
   kubectl -n osrm create job osrm-bus-rebuild   --from=cronjob/osrm-bus-redeploy-cronjob
   kubectl -n osrm create job osrm-rail-rebuild  --from=cronjob/osrm-rail-redeploy-cronjob
   kubectl -n osrm create job osrm-ferry-rebuild --from=cronjob/osrm-ferry-redeploy-cronjob
   # ...repeat for any other profiles (car, water)
   ```

   Trigger this **promptly**: the deploy tooling auto-rolls-back a rollout that never goes
   healthy, reverting to the previous (old-engine) image. If that happens before the graph
   is rebuilt, you land on old-engine + new-data (the same incompatibility, mirrored) — just
   re-deploy the new image once the rebuild has populated the prefix.

4. Each job's final step restarts its deployment, which then pulls the freshly-built graph
   and converges. Verify: `kubectl -n osrm rollout status deploy/osrm-bus` and that no pods
   remain in CrashLoopBackOff.
5. Rollback: revert the image and `data.osrmVersion` to the previous prefix and redeploy —
   the old graph data is still there.

#### Environments still on the pre-rename ("water") chart

The deploy-then-rebuild flow above is only safe when the environment is already on the
current chart, where the `osrm-water` Service selects `app: osrm-ferry` and the ferry
Deployment exists (dev). An environment still on the **pre-rename chart** (at time of
writing, **tst and prd**) has `osrm-water` as a *Deployment* (`app: osrm-water`) and the
`osrm-water` Service selects `app: osrm-water` — there is no `osrm-ferry`. Deploying the
current chart there does the **water→ferry rename and the v26 bump in one step**, which
changes the risk:

- **bus / rail** — name unchanged, so old pods keep serving while new ones crashloop on the
  empty prefix. No outage (same as above).
- **ferry / water** — the deploy repoints the `osrm-water` Service from `app: osrm-water` to
  `app: osrm-ferry`. The old pods stop receiving traffic immediately and the new ferry pods
  aren't ready yet, so **`osrm-water.<env>.entur.internal` goes down** until ferry is healthy.
  With crashloop-then-rebuild that outage lasts the whole ~30-min rebuild.

So for these environments use **build-then-flip** instead — pre-populate the new prefix
*before* deploying, so the new pods (including ferry) come up healthy immediately:

1. Pre-build the graph into the new prefix without touching the live deployments, using the
   **exact image you are about to deploy**:

   ```bash
   ./prebuild-osrm-graph.sh tst v26 <osrm-api-image-tag>
   ```

   This runs download → extract → contract → upload for bus, rail and water into
   `gs://ror-osrm-internal-<env>/v26/…`, with no redeploy — the running v6 pods are
   unaffected. Wait for all three Jobs to complete and verify the data landed.
2. Deploy the current chart (v26 image + `osrmVersion=v26` + the rename). Every new pod finds
   its data already present, so bus/rail converge with no outage and ferry/water has only a
   brief (~1–2 min) readiness gap when the Service flips, not a 30-min one.
3. Verify routing on all hosts, then **delete the now-orphaned `osrm-water` Deployment**.

**Before deleting `osrm-water` in any environment, check the Service selector:**
`kubectl -n osrm get svc osrm-water -o jsonpath='{.spec.selector}'`.
`app: osrm-ferry` ⇒ the Deployment is an un-pruned orphan, safe to delete. `app: osrm-water`
⇒ it is still the **live backend** (pre-rename chart) — deleting it takes ferry/water down.

## Running locally

You can modify profile code locally and test it as follows:

1. After you changed some profile code (say `profiles/bus.lua`), run 
   `docker build -t osrm .`
2. Make sure you have an OSM protobuf file for the area you are interested in. Let's assume
    you have a `data/` folder that contains this file. Assume it is called `norway.osm.pbf`.
3. Run `osrm-extract` like this:
   `docker run -t -v "${PWD}/data:/data" osrm osrm-extract -p /opt/bus.lua /data/norway.osm.pbf`
4. Run `osrm-contract` like this:
   `docker run -t -v "${PWD}/data:/data" osrm osrm-contract  /data/norway.osrm`
5. Finally you can run the routing service itself, using this data:
   `docker run -t -i -p 5001:5000 -v "${PWD}/data:/data" osrm osrm-routed  /data/norway.osrm`

The OSRM routing service is now available on "http://localhost:5001".

You can use `osrm-frontend` to test it:

    docker run -p 9966:9966 -e OSRM_BACKEND=http://localhost:5001 osrm/osrm-frontend

Please note that in this example I have used port 5001 on the host machine. This is because
on recent versions of macOS, port 5000 is reserved the AirTunes.

You can test it by visiting [http://container-ip:8080](http://container-ip:8080)

## Testing

This repository includes a comprehensive testing framework to verify routing functionality across different transportation profiles (bus, rail, ferry). The tests help detect regressions when upgrading OSRM versions or modifying routing profiles.

### Test Framework Overview

The testing framework:
- Tests bus, rail, and ferry routing profiles using real OSM data from Zeeland, Netherlands
- Compares routing responses against established baselines to detect changes
- Uses Docker Compose to spin up isolated test environments
- Runs automatically in GitHub Actions on profile changes

### Running Tests Locally

#### Prerequisites
- Docker and Docker Compose
- Bash shell

#### Quick Start
```bash
# Run the complete test suite
./run-test.sh
```

This will:
1. Download OSM test data (if not already present)
2. Start OSRM services for all profiles
3. Run routing tests against known working routes
4. Report pass/fail results

#### Creating New Baselines
If you've made intentional changes to routing profiles and need to update the expected responses:

```bash
# Regenerate baseline files
./update-baselines.sh

# Commit the updated baselines
git add test/expected/
git commit -m "Update routing baselines after profile changes"
```

### Test Routes

The framework tests these verified routes in Zeeland:

- **Kruiningen to Perkpolder ferry**: `4.0295,51.4481;4.0577,51.3644`
- **Anna Jacobapolder to Kats ferry**: `3.9686,51.6356;3.8708,51.6467`

These routes work across all three transportation profiles and represent real-world routing scenarios.

### GitHub Actions Integration

Tests run automatically on:
- Push to main branch (`rutebanken`)
- Pull requests targeting this branch
- Changes to profiles, Dockerfile, or test configuration

The CI workflow:
- Downloads fixed-date OSM data for consistency
- Builds and tests all routing profiles
- Compares results against committed baselines
- Fails if routing responses have changed unexpectedly

### Test Data

Tests use a fixed snapshot of OSM data (`zeeland-240101.osm.pbf`) to ensure consistent results between local testing and CI/CD. This prevents test failures due to daily OSM data updates.

### Troubleshooting

**Tests failing after profile changes?**
- Review the changes to ensure they're intentional
- Run `./update-baselines.sh` to create new expected responses
- Commit the updated baseline files

**Services not starting?**
- Check that Docker has sufficient resources
- Verify OSM test data downloaded correctly: `ls -la test-data/zeeland-latest.osm.pbf`

**Ferry tests failing?**
- Ferry routing requires specific route types in OSM data
- The test routes are verified to work with the Zeeland dataset
- Other regions may not have suitable ferry connections
