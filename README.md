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

Recommended procedure, per environment (dev → tst → prd):

1. Merge the base-image bump (and any profile fixes it requires — a new engine can add
   Lua profile properties; run `./run-test.sh` to catch extract crashes before deploying).
   CD builds the new custom image.
2. **For a safe, rollback-able cutover:** bump `data.osrmVersion` to a fresh prefix
   (e.g. `v6` → `v26`) so the old graph data survives at the old prefix. The new prefix is
   empty until step 3, so do not deploy the new image before building. (Overwriting the
   existing prefix in place also works but is forward-only — you lose the rollback path,
   because the old engine can't read the newly-built data either.)
3. Rebuild the graph with the new engine by triggering each profile's (suspended) build
   CronJob, which runs extract → contract → upload → redeploy:

   ```bash
   kubectl -n osrm create job osrm-bus-rebuild   --from=cronjob/osrm-bus-redeploy-cronjob
   kubectl -n osrm create job osrm-rail-rebuild  --from=cronjob/osrm-rail-redeploy-cronjob
   kubectl -n osrm create job osrm-ferry-rebuild --from=cronjob/osrm-ferry-redeploy-cronjob
   # ...repeat for any other profiles (car, water)
   ```

4. Each job's final step restarts its deployment, which then pulls the freshly-built graph.
   Verify: `kubectl -n osrm rollout status deploy/osrm-bus` and that no pods remain in
   CrashLoopBackOff.
5. Rollback (only if you used a fresh prefix in step 2): revert both the image and
   `data.osrmVersion`, then redeploy.

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
