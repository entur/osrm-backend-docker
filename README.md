# Dockerfile for osrm-backend [![CircleCI](https://circleci.com/gh/entur/osrm-backend-docker/tree/rutebanken.svg?style=svg)](https://circleci.com/gh/entur/osrm-backend-docker/tree/rutebanken)
This container run [osrm-backend](https://github.com/Project-OSRM/osrm-backend) project.
Open Source Routing Machine (OSRM) Docker Image [\[Docker Hub\]](https://hub.docker.com/r/cartography/osrm-backend-docker/)

## Installation

1. Install [Docker](https://www.docker.com/)

2. Manual deploy (optional).

  Pull automated build from Docker Hub:
  ```
  $ docker pull cartography/osrm-backend-docker
  ```
  or build from GitHub:
  ```
  $ docker build -t="cartography/osrm-backend-docker" github.com/cartography/osrm-backend-docker
  ```
  or you can clone & build:  
  ```
  $ git clone https://github.com/cartography/osrm-backend-docker.git  
  $ docker build -t="cartography/osrm-backend-docker" osrm-backend-docker/
  ```

## Usage
Run it:  
```
docker run -d -p 5000:5000 cartography/osrm-backend-docker:latest osrm profile "http://your/path/to/data.osm.pbf"
```  

Explanation:  
- `-d` - run container in background and print container ID
- `-p 5000:5000` - publish a container port to host
- `osrm` - go via entrypoint script, w/o osrm keyword - classic mode
- `profile` - the profile you want to run
- `url` - link to OSM data in PBF format

For example:  
```
docker run -d -p 5000:5000 --name osrm-api cartography/osrm-backend-docker:latest osrm car "http://download.geofabrik.de/north-america/us/california-latest.osm.pbf"
```

## Start OSRM Frontend (currently not supporting v5.0.0)

    docker run -d --link osrm-api:api --name osrm-mos-front --restart=always -p 8080:80 cartography/osrm-frontend-docker

You must `--link` osrm-frontend container with osrm-api with `api` tag. Or use `API_PORT_5000_TCP_ADDR` and `API_PORT_5000_TCP_PORT` variables to set host and port of the api.

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
