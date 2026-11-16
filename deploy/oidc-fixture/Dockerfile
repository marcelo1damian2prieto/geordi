FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /fixture
COPY pom.xml ./
COPY src src
RUN mvn -B -ntp -DskipTests package

FROM eclipse-temurin:21-jre-jammy
RUN useradd --system --uid 10002 --create-home oidcfixture
WORKDIR /app
COPY --from=build /fixture/target/oidc-fixture.jar /app/oidc-fixture.jar
COPY --from=build /fixture/target/lib /app/lib
USER 10002
EXPOSE 443 8444
ENTRYPOINT ["java", "-cp", "/app/oidc-fixture.jar:/app/lib/*", "io.geordi.test.oidc.OidcFixtureServer"]
