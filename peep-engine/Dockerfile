FROM rust:1.88-bookworm AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --locked --release

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 peep \
    && install -d -o peep -g peep /data

COPY --from=builder /build/target/release/peep-engine /usr/local/bin/peep-engine

WORKDIR /app
ENV PEEP_ENGINE_ADDR=0.0.0.0:8787

EXPOSE 8787

CMD ["peep-engine"]
