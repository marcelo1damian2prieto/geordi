FROM busybox:1.37.0-musl AS healthcheck

FROM grafana/loki:3.7.2
COPY --from=healthcheck /bin/busybox /bin/busybox
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=12 \
  CMD ["/bin/busybox", "wget", "-q", "--spider", "http://127.0.0.1:3100/ready"]
