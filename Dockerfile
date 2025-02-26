FROM osrm/osrm-backend:v5.25.0

COPY profiles/. /opt/

WORKDIR /deployments
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh
RUN addgroup appuser && adduser --disabled-password appuser --ingroup appuser --gecos ""
RUN mkdir osrm-data && chown appuser:appuser . && chown appuser:appuser osrm-data
ENTRYPOINT ["/deployments/docker-entrypoint.sh"]

EXPOSE 5000
