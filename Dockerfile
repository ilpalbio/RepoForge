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
    && yq --version \
    && command -v jq \
    && jq --version

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

# Stage 3: verifica semanticamente il JSON prodotto dal loader.
FROM loader-test AS validator-test

COPY scripts/validator.sh ./scripts/validator.sh

RUN chmod +x ./scripts/validator.sh

RUN ./scripts/validator.sh /tmp/repoforge-config.json

# Stage 4: prepara il test interattivo di autenticazione e autorizzazione GitHub.
# Il login viene eseguito a runtime con `docker run -it`, mai durante la build.
FROM validator-test AS auth-test

COPY scripts/github/auth.sh ./scripts/github/auth.sh

RUN chmod +x ./scripts/github/auth.sh \
    && bash -n ./scripts/github/auth.sh

ENTRYPOINT ["./scripts/github/auth.sh"]
CMD ["--help"]

# Stage 5: sincronizza due volte le label e verifica l'idempotenza.
# Il test modifica realmente il repository passato a `docker run`.
FROM auth-test AS labels-test

COPY scripts/github/labels.sh ./scripts/github/labels.sh

RUN chmod +x ./scripts/github/labels.sh \
    && bash -n ./scripts/github/labels.sh

ENTRYPOINT ["bash", "-c", "if [[ \"$1\" == \"--help\" ]]; then exec ./scripts/github/labels.sh --help; fi; ./scripts/github/labels.sh \"$1\" /tmp/repoforge-config.json && output=\"$(./scripts/github/labels.sh \"$1\" /tmp/repoforge-config.json)\" && printf '%s\\n' \"$output\" && grep -Fq 'create=0, aggiornate=0' <<<\"$output\"", "--"]
CMD ["--help"]

# Stage 6: sincronizza due volte le milestone e verifica l'idempotenza.
# Il test modifica realmente il repository passato a `docker run`.
FROM auth-test AS milestones-test

COPY scripts/github/milestones.sh ./scripts/github/milestones.sh

RUN chmod +x ./scripts/github/milestones.sh \
    && bash -n ./scripts/github/milestones.sh

ENTRYPOINT ["bash", "-c", "if [[ \"$1\" == \"--help\" ]]; then exec ./scripts/github/milestones.sh --help; fi; ./scripts/github/milestones.sh \"$1\" /tmp/repoforge-config.json && output=\"$(./scripts/github/milestones.sh \"$1\" /tmp/repoforge-config.json)\" && printf '%s\\n' \"$output\" && grep -Fq 'create=0, aggiornate=0' <<<\"$output\"", "--"]
CMD ["--help"]

# Stage 7: prepara le dipendenze, sincronizza due volte le issue e verifica
# l'idempotenza. Il test modifica realmente il repository passato a `docker run`.
FROM auth-test AS issues-test

COPY scripts/github/labels.sh ./scripts/github/labels.sh
COPY scripts/github/milestones.sh ./scripts/github/milestones.sh
COPY scripts/github/issues.sh ./scripts/github/issues.sh

RUN chmod +x \
      ./scripts/github/labels.sh \
      ./scripts/github/milestones.sh \
      ./scripts/github/issues.sh \
    && bash -n \
      ./scripts/github/labels.sh \
      ./scripts/github/milestones.sh \
      ./scripts/github/issues.sh

ENTRYPOINT ["bash", "-c", "if [[ \"$1\" == \"--help\" ]]; then exec ./scripts/github/issues.sh --help; fi; ./scripts/github/labels.sh \"$1\" /tmp/repoforge-config.json && ./scripts/github/milestones.sh \"$1\" /tmp/repoforge-config.json && ./scripts/github/issues.sh \"$1\" /tmp/repoforge-config.json && output=\"$(./scripts/github/issues.sh \"$1\" /tmp/repoforge-config.json)\" && printf '%s\\n' \"$output\" && grep -Fq 'create=0, aggiornate=0' <<<\"$output\"", "--"]
CMD ["--help"]

# Stage 8: applica due volte stato, assegnatari e dipendenze delle issue,
# verificando che il secondo passaggio non produca modifiche.
FROM issues-test AS issues-metadata-test

COPY scripts/github/issues-metadata.sh ./scripts/github/issues-metadata.sh
COPY tests/fixtures/issues-metadata/ ./tests/fixtures/issues-metadata/

RUN chmod +x ./scripts/github/issues-metadata.sh \
    && bash -n ./scripts/github/issues-metadata.sh \
    && jq empty ./tests/fixtures/issues-metadata/*.json \
    && if ./scripts/github/issues-metadata.sh \
      owner/repository \
      ./tests/fixtures/issues-metadata/invalid-state.json; then exit 1; fi

ENTRYPOINT ["bash", "-c", "if [[ \"$1\" == \"--help\" ]]; then exec ./scripts/github/issues-metadata.sh --help; fi; fixture=./tests/fixtures/issues-metadata/valid.json; ./scripts/github/labels.sh \"$1\" /tmp/repoforge-config.json && ./scripts/github/milestones.sh \"$1\" /tmp/repoforge-config.json && ./scripts/github/issues.sh \"$1\" /tmp/repoforge-config.json && ./scripts/github/issues-metadata.sh \"$1\" \"$fixture\" && output=\"$(./scripts/github/issues-metadata.sh \"$1\" \"$fixture\")\" && printf '%s\\n' \"$output\" && grep -Fq 'metadati_aggiornati=0, dipendenze_aggiunte=0, dipendenze_rimosse=0' <<<\"$output\"", "--"]
CMD ["--help"]

# Stage 9: esegue l'intero flusso e verifica il riepilogo finale.
# Il test modifica realmente il repository passato a `docker run`.
FROM issues-metadata-test AS summary-test

COPY scripts/github/summary.sh ./scripts/github/summary.sh

RUN chmod +x ./scripts/github/summary.sh \
    && bash -n ./scripts/github/summary.sh

ENTRYPOINT ["bash", "-c", "if [[ \"$1\" == \"--help\" ]]; then exec ./scripts/github/summary.sh --help; fi; config=/tmp/repoforge-config.json; ./scripts/github/labels.sh \"$1\" \"$config\" && ./scripts/github/milestones.sh \"$1\" \"$config\" && ./scripts/github/issues.sh \"$1\" \"$config\" && ./scripts/github/issues-metadata.sh \"$1\" \"$config\" && output=\"$(./scripts/github/summary.sh \"$1\" \"$config\")\" && printf '%s\\n' \"$output\" && grep -Fq 'Sincronizzazione completa.' <<<\"$output\"", "--"]
CMD ["--help"]
