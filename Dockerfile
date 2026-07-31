FROM ghcr.io/project-osrm/osrm-backend:v26.4.0

RUN apk update \
    && apk upgrade \
    && rm -rf /var/cache/apk/*

COPY profiles/. /opt/
COPY profiles/lib/. /opt/lib/

RUN addgroup appuser && adduser --disabled-password appuser --ingroup appuser --gecos ""

EXPOSE 5000
