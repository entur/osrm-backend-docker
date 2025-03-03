FROM ghcr.io/project-osrm/osrm-backend:v5.27.1

WORKDIR /deployments
COPY profiles/. /opt/
COPY profiles/lib/. /opt/lib/
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh
RUN addgroup appuser && adduser --disabled-password appuser --ingroup appuser --gecos ""
RUN mkdir osrm-data && chown appuser:appuser . && chown appuser:appuser osrm-data
ENTRYPOINT ["/deployments/docker-entrypoint.sh"]

EXPOSE 5000
