# Dockerfile -- the REST service and the pages of the bank (bk-api.jar) as a container image, for the cluster
# k3s (k8s/bank.yaml). The jar is built before (api/: ./mvnw package, or install_service.sh), then from the
# root of the repo:
#
#   podman build -f k8s/Dockerfile -t localhost/bank/bk-api:$(git rev-parse --short HEAD) .
#
# (k8s/ship_image.sh does it and takes the image to the nodes.) The base: a Java 21 runtime (the jar wants 17
# or later); BASE another one where docker.io is not reachable (e.g. mirror.gcr.io/library/eclipse-temurin:21-jre).
# No password in the image: the database from the environment of the pod (BK_DB_URL, BK_DB_USER,
# BK_DB_PASSWORD: a Secret of the cluster).
ARG BASE=docker.io/library/eclipse-temurin:21-jre
FROM ${BASE}
LABEL org.opencontainers.image.title="bk-api" org.opencontainers.image.description="The REST service and the pages of the bank"
WORKDIR /app
COPY api/target/bk-api.jar /app/bk-api.jar
# a user of its own, not root (any uid works: OpenShift too)
RUN useradd --system --uid 10001 --home-dir /app bkapi && chown -R 10001:0 /app && chmod -R g=u /app
USER 10001
ENV BK_API_BIND=0.0.0.0 BK_API_PORT=8091 \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -Duser.timezone=Europe/Athens"
EXPOSE 8091
ENTRYPOINT ["java", "-jar", "/app/bk-api.jar"]
