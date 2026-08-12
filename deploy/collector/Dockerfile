FROM busybox:1.37.0-musl AS healthcheck

FROM otel/opentelemetry-collector:0.157.0
COPY --from=healthcheck /bin/busybox /bin/busybox
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=12 \
  CMD ["/bin/busybox", "wget", "-q", "--spider", "http://localhost:13133/"]
