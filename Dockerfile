FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /opt/repoforge

COPY scripts/installer.sh ./scripts/installer.sh

RUN chmod +x ./scripts/installer.sh \
    && ./scripts/installer.sh \
    && command -v gh \
    && gh --version

# Riesegue l'installer per verificare che non reinstalli GitHub CLI.
CMD ["./scripts/installer.sh"]
