FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /workspace

COPY pom.xml ./
RUN mvn -B -ntp dependency:go-offline
COPY src src
RUN mvn -B -ntp package -DskipTests && cp target/geordi-demo-downstream-*.jar /tmp/application.jar

FROM alpine:3.22.1 AS otel-java-agent
ARG OTEL_JAVA_AGENT_VERSION=2.28.1
ARG OTEL_JAVA_AGENT_SHA256=faa89bdeebf9b1f52be4a4374689176717b02a59df2d8f8b6eb9aa39f9292589
RUN wget --no-verbose --output-document=/opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_JAVA_AGENT_VERSION}/opentelemetry-javaagent.jar" \
    && echo "${OTEL_JAVA_AGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

FROM busybox:1.37.0-musl AS healthcheck

FROM eclipse-temurin:21-jre-jammy
RUN useradd --system --uid 10001 --create-home geordi
WORKDIR /app
COPY --from=build /tmp/application.jar application.jar
COPY --from=otel-java-agent /opentelemetry-javaagent.jar /opt/opentelemetry/opentelemetry-javaagent.jar
COPY --from=healthcheck /bin/busybox /bin/busybox
RUN chown -R geordi:geordi /app /opt/opentelemetry
USER 10001
EXPOSE 8082
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=6 \
  CMD ["/bin/busybox", "wget", "-q", "--spider", "http://localhost:8082/actuator/health/readiness"]
ENTRYPOINT ["sh", "-c", "export OTEL_RESOURCE_ATTRIBUTES=\"${OTEL_RESOURCE_ATTRIBUTES},service.instance.id=$(cat /proc/sys/kernel/random/uuid)\"; exec java -javaagent:/opt/opentelemetry/opentelemetry-javaagent.jar -jar /app/application.jar"]
