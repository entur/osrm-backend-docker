FROM ghcr.io/project-osrm/osrm-backend:v6.0.0-debian

RUN apt-get -y update \
    && apt-get -y upgrade \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean \
    && rm -rf /var/cache/apt/archives/

COPY profiles/. /opt/
COPY profiles/lib/. /opt/lib/

RUN addgroup appuser && adduser --disabled-password appuser --ingroup appuser --gecos ""

EXPOSE 5000
