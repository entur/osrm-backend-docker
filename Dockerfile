FROM ghcr.io/project-osrm/osrm-backend:v6.0.0-alpine

RUN apk update \
    && apk upgrade \
    && rm -rf /var/cache/apk/*

COPY profiles/. /opt/
COPY profiles/lib/. /opt/lib/

RUN addgroup appuser && adduser --disabled-password appuser --ingroup appuser --gecos ""

EXPOSE 5000
