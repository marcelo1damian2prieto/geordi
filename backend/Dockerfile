FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /workspace

COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw -B -ntp dependency:go-offline

COPY src src
RUN ./mvnw -B -ntp verify && cp target/geordi-backend-*.jar /tmp/application.jar

FROM alpine:3.22.1 AS otel-java-agent
ARG OTEL_JAVA_AGENT_VERSION=2.28.1
ARG OTEL_JAVA_AGENT_SHA256=faa89bdeebf9b1f52be4a4374689176717b02a59df2d8f8b6eb9aa39f9292589
RUN wget --no-verbose --output-document=/opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_JAVA_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    && echo "${OTEL_JAVA_AGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

FROM busybox:1.37.0-musl AS healthcheck

FROM eclipse-temurin:21-jre-jammy AS runtime
RUN useradd --system --uid 10001 --create-home geordi
WORKDIR /app
COPY --from=build /tmp/application.jar application.jar
COPY --from=otel-java-agent /opentelemetry-javaagent.jar /opt/opentelemetry/opentelemetry-javaagent.jar
COPY --from=healthcheck /bin/busybox /bin/busybox
RUN mkdir -p /var/lib/geordi/alerts /var/lib/geordi/alerts-m10 /var/lib/geordi/alerts-m12 \
    && chown -R geordi:geordi /app /opt/opentelemetry /var/lib/geordi
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=6 \
  CMD ["/bin/busybox", "wget", "-q", "--spider", "http://localhost:8080/actuator/health/readiness"]
ENTRYPOINT ["sh", "-c", "export OTEL_RESOURCE_ATTRIBUTES=\"${OTEL_RESOURCE_ATTRIBUTES},service.instance.id=$(cat /proc/sys/kernel/random/uuid)\"; exec java -javaagent:/opt/opentelemetry/opentelemetry-javaagent.jar -jar /app/application.jar"]

# Keep the developer default source-building runtime as the final target below.

FROM eclipse-temurin:21-jre-jammy AS ci-artifact
ARG VERIFIED_JAR_SHA256
ARG SOURCE_REVISION
COPY .ci-artifact/application.jar /verified/application.jar
RUN test -n "$VERIFIED_JAR_SHA256" && test -n "$SOURCE_REVISION" \
    && echo "$VERIFIED_JAR_SHA256  /verified/application.jar" | sha256sum -c -

FROM eclipse-temurin:21-jre-jammy AS ci-runtime
ARG SOURCE_REVISION
ARG VERIFIED_JAR_SHA256
LABEL org.opencontainers.image.revision=$SOURCE_REVISION \
      io.geordi.verified-artifact.sha256=$VERIFIED_JAR_SHA256
RUN useradd --system --uid 10001 --create-home geordi
WORKDIR /app
COPY --from=ci-artifact /verified/application.jar application.jar
COPY --from=otel-java-agent /opentelemetry-javaagent.jar /opt/opentelemetry/opentelemetry-javaagent.jar
COPY --from=healthcheck /bin/busybox /bin/busybox
RUN mkdir -p /var/lib/geordi/alerts /var/lib/geordi/alerts-m10 /var/lib/geordi/alerts-m12 && chown -R geordi:geordi /app /opt/opentelemetry /var/lib/geordi
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=6 CMD ["/bin/busybox", "wget", "-q", "--spider", "http://localhost:8080/actuator/health/readiness"]
ENTRYPOINT ["sh", "-c", "export OTEL_RESOURCE_ATTRIBUTES=\"${OTEL_RESOURCE_ATTRIBUTES},service.instance.id=$(cat /proc/sys/kernel/random/uuid)\"; exec java -javaagent:/opt/opentelemetry/opentelemetry-javaagent.jar -jar /app/application.jar"]

FROM runtime AS default-runtime
