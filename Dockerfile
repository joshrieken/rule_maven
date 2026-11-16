# syntax=docker/dockerfile:1.7
# Production image: build an Elixir release, run it on slim Debian as uid 1000.
# Built and started by compose.yaml (scripts/deploy.sh on the server).

ARG ELIXIR_VERSION=1.20.1
ARG OTP_VERSION=29.0.2
ARG DEBIAN_VERSION=bookworm-20260610-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
      python3 postgresql-client poppler-utils rsync
WORKDIR /app
# MIX_HOME outside /root: the tools container (compose service "tools") reuses this
# stage as uid 1000. python3/psql/poppler are for the import scripts run there.
ENV MIX_ENV=prod MIX_HOME=/opt/mix HEX_HOME=/opt/hex
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/opt/hex/packages,sharing=locked mix deps.get --only prod
COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY priv priv
COPY lib lib
COPY rel rel
# _build lives in a BuildKit cache that survives between builds, so deps and app
# recompile only what changed (a cold deps.compile alone is ~2 min). No bundler:
# assets are committed plain files; digesting is the whole asset build.
# The release is written outside the cache so the runtime stage can copy it.
RUN --mount=type=cache,target=/app/_build,id=rulemaven-build,sharing=locked \
    mix deps.compile && mix compile && mix assets.deploy && \
    mix release --overwrite --path /app/release

FROM debian:${DEBIAN_VERSION} AS runtime
# poppler (pdfinfo/pdftoppm/pdftotext) + tesseract: rulebook extraction. ghostscript: PdfCompress.
# curl: healthcheck.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates curl \
      poppler-utils tesseract-ocr tesseract-ocr-eng ghostscript && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod PHX_SERVER=true PORT=4000 UPLOADS_DIR=/data/files

# uid 1000 = the server's deploy user, so the bind-mounted ./data/files is writable.
RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --home /app app && \
    mkdir -p /data/files && chown app:app /data/files
WORKDIR /app
COPY --from=build --chown=app:app /app/release ./
USER app
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD curl -fsS http://127.0.0.1:4000/health >/dev/null || exit 1
CMD ["sh", "-c", "/app/bin/migrate && exec /app/bin/server"]
