FROM ghcr.io/project-osrm/osrm-backend:v5.27.1

COPY profiles/. /opt/
COPY profiles/lib/. /opt/lib/

RUN addgroup appuser && adduser --disabled-password appuser --ingroup appuser --gecos ""

EXPOSE 5000
