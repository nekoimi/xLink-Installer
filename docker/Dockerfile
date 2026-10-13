# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates libgcc-s1 libssl3 python3 tzdata \
    && rm -rf /var/lib/apt/lists/*

FROM base AS downloads
ARG TARGETARCH
COPY download.py /download.py
RUN python3 /download.py "${TARGETARCH}" /out

FROM base
LABEL org.opencontainers.image.title="xLink" \
      org.opencontainers.image.description="Xray VLESS REALITY and rathole Noise server" \
      org.opencontainers.image.source="https://github.com/nekoimi/xLink-Installer" \
      org.opencontainers.image.licenses="AGPL-3.0-only"
COPY --from=downloads /out/ /usr/local/bin/
RUN xray version && rathole --version
COPY app.py /opt/xlink/app.py
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai
WORKDIR /data
VOLUME ["/data"]
EXPOSE 443/tcp 2333/tcp 8443/tcp
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python3", "/opt/xlink/app.py", "healthcheck"]
ENTRYPOINT ["python3", "/opt/xlink/app.py"]
CMD ["serve"]
