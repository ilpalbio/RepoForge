ARG UBUNTU_VERSION=24.04

# Stage 1: verifica l'installazione delle dipendenze su un sistema pulito.
FROM ubuntu:${UBUNTU_VERSION} AS installer-test

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /opt/repoforge

COPY scripts/installer.sh ./scripts/installer.sh

RUN chmod +x ./scripts/installer.sh \
    && ./scripts/installer.sh

RUN command -v gh \
    && gh --version \
    && command -v yq \
    && yq --version

# La seconda esecuzione verifica che l'installer sia idempotente.
RUN ./scripts/installer.sh

# Stage 2: verifica il caricamento e l'unione della configurazione YAML.
FROM installer-test AS loader-test

COPY scripts/loader.sh ./scripts/loader.sh
COPY repoforge.yaml ./repoforge.yaml
COPY config/ ./config/

RUN chmod +x ./scripts/loader.sh

RUN ./scripts/loader.sh ./repoforge.yaml > /tmp/repoforge-config.json

RUN yq eval -e \
    '.version == 1 and (.repository | type == "!!map") and (.labels | type == "!!seq") and (.milestones | type == "!!seq") and (.issues | type == "!!seq")' \
    /tmp/repoforge-config.json > /dev/null

CMD ["./scripts/loader.sh", "./repoforge.yaml"]
