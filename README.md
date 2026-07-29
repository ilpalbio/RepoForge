# RepoForge

RepoForge è uno strumento da riga di comando scritto in Bash che permette di
configurare e popolare un repository GitHub in modo massivo partendo da file
YAML versionabili.

Utilizza [GitHub CLI](https://cli.github.com/) per creare e sincronizzare:

- impostazioni del repository;
- label;
- milestone;
- issue;
- assegnatari;
- collaboratori e team;
- regole di protezione dei branch;
- funzionalità opzionali come Wiki, Discussions e Projects.

L'obiettivo è trattare la configurazione operativa di un repository come codice:
i file YAML possono essere revisionati, condivisi e riutilizzati su repository
diversi.

## Perché RepoForge

Creare manualmente decine di label, milestone e issue è lento e soggetto a
errori. RepoForge raccoglie la configurazione in file dichiarativi e la applica
tramite `gh`.

Il processo è progettato per essere **idempotente**: eseguendo più volte lo
stesso comando, RepoForge aggiorna le risorse già esistenti invece di crearne
copie.

## Requisiti

- Bash 4.3 o successivo;
- [GitHub CLI](https://cli.github.com/);
- [jq](https://jqlang.github.io/jq/);
- [yq v4](https://github.com/mikefarah/yq/);
- accesso in scrittura al repository interessato.

Prima dell'utilizzo è necessario autenticare GitHub CLI:

```bash
gh auth login
gh auth status
```

Su macOS è possibile installare le dipendenze con Homebrew:

```bash
brew install gh jq yq
```

## Struttura del progetto

```text
repoforge/
├── repoforge.sh
├── repoforge.yaml
└── config/
    ├── settings.yaml
    ├── labels.yaml
    ├── milestones.yaml
    ├── collaborators.yaml
    ├── branches.yaml
    └── issues/
        ├── authentication.yaml
        ├── frontend.yaml
        ├── backend.yaml
        └── infrastructure.yaml
```

| Percorso | Scopo |
| --- | --- |
| `repoforge.sh` | Legge, valida e applica la configurazione tramite `gh`. |
| `repoforge.yaml` | Manifest principale del progetto. |
| `config/settings.yaml` | Impostazioni generali e funzionalità del repository. |
| `config/labels.yaml` | Catalogo centralizzato delle label. |
| `config/milestones.yaml` | Release, scadenze e milestone. |
| `config/collaborators.yaml` | Collaboratori, team e permessi. |
| `config/branches.yaml` | Branch predefinito e regole di protezione. |
| `config/issues/*.yaml` | Issue suddivise per area, epic o componente. |

La separazione in più file evita un unico YAML difficile da mantenere. I file
delle issue possono essere organizzati liberamente, per esempio per team,
modulo, sprint o epic.

## Manifest principale

`repoforge.yaml` definisce il repository di destinazione e indica quali file
caricare:

```yaml
version: 1

repository:
  owner: acme
  name: my-project

sources:
  settings: config/settings.yaml
  labels: config/labels.yaml
  milestones: config/milestones.yaml
  collaborators: config/collaborators.yaml
  branches: config/branches.yaml
  issues:
    - config/issues/*.yaml
```

I percorsi sono relativi alla posizione del manifest. La voce `issues` accetta
più file e pattern glob.

## Identificatori stabili

Le risorse dichiarate nel progetto usano un campo `id` stabile:

```yaml
id: priority-high
name: priority:high
```

Le altre configurazioni fanno riferimento all'`id`, non al nome visualizzato:

```yaml
labels:
  - priority-high
```

Questo permette di rinominare una label, una milestone o un'altra risorsa senza
dover modificare tutti i riferimenti. Un `id`:

- deve essere univoco all'interno del proprio tipo di risorsa;
- dovrebbe contenere solo lettere minuscole, numeri e trattini;
- non dovrebbe essere cambiato dopo la prima sincronizzazione.

## Configurazione del repository

Esempio di `config/settings.yaml`:

```yaml
settings:
  description: Applicazione principale ACME
  homepage: https://example.com
  visibility: private
  default_branch: main

  features:
    issues: true
    projects: true
    wiki: false
    discussions: true

  merge:
    squash: true
    merge_commit: false
    rebase: true
    delete_branch_on_merge: true
```

Questa sezione descrive metadati, visibilità, funzionalità abilitate e strategia
di merge del repository.

## Label

Esempio di `config/labels.yaml`:

```yaml
labels:
  - id: priority-high
    name: priority:high
    color: D73A4A
    description: Intervento prioritario

  - id: type-feature
    name: type:feature
    color: 1D76DB
    description: Nuova funzionalità

  - id: type-bug
    name: type:bug
    color: B60205
    description: Comportamento inatteso
```

Il colore deve essere espresso come valore esadecimale di sei caratteri, senza
il simbolo `#`.

## Milestone

Esempio di `config/milestones.yaml`:

```yaml
milestones:
  - id: release-v1
    title: Versione 1.0
    description: Prima release pubblica
    due_on: 2026-09-30
    state: open
```

Valori ammessi per `state`:

- `open`;
- `closed`.

Le issue possono collegarsi alla milestone usando `release-v1`, anche se il
titolo visualizzato viene modificato successivamente.

## Issue

Le issue sono divise in uno o più file dentro `config/issues/`.

Esempio di `config/issues/authentication.yaml`:

```yaml
issues:
  - id: auth-login
    title: Implementare il login

    body: |
      Aggiungere autenticazione e gestione della sessione.

      ## Criteri di accettazione

      - Login con credenziali valide
      - Errore con credenziali errate
      - Logout e invalidazione della sessione

    labels:
      - priority-high
      - type-feature

    milestone: release-v1

    assignees:
      - octocat

    dependencies: []
    state: open
```

Il campo `body` supporta Markdown. I campi `labels` e `milestone` contengono gli
identificatori definiti negli altri file.

`dependencies` può descrivere relazioni logiche tra issue:

```yaml
issues:
  - id: deploy-production
    title: Eseguire il deploy in produzione
    dependencies:
      - auth-login
      - frontend-dashboard
```

RepoForge può riportare queste relazioni nel corpo delle issue o convertirle in
collegamenti supportati dalle API GitHub.

## Collaboratori e team

Esempio di `config/collaborators.yaml`:

```yaml
collaborators:
  - username: octocat
    permission: push

teams:
  - organization: acme
    slug: backend
    permission: maintain
```

I permessi utilizzabili dipendono dal tipo di account, dal piano GitHub e dai
privilegi dell'utente autenticato.

## Protezione dei branch

Esempio di `config/branches.yaml`:

```yaml
branches:
  - name: main
    protection:
      required_reviews: 2
      dismiss_stale_reviews: true
      require_code_owner_reviews: true
      required_checks:
        - test
        - lint
      enforce_admins: false
      allow_force_pushes: false
      allow_deletions: false
```

Gli status check devono corrispondere ai nomi effettivamente pubblicati dalle
GitHub Actions o dagli altri sistemi CI.

## Utilizzo

Rendere eseguibile lo script:

```bash
chmod +x repoforge.sh
```

Validare la configurazione e vedere le operazioni previste:

```bash
./repoforge.sh --dry-run repoforge.yaml
```

Applicare la configurazione:

```bash
./repoforge.sh apply repoforge.yaml
```

Sovrascrivere il repository indicato nel manifest:

```bash
./repoforge.sh apply repoforge.yaml --repo altra-org/altro-repo
```

## Flusso di esecuzione

Durante l'esecuzione RepoForge:

1. carica `repoforge.yaml`;
2. risolve i percorsi e i glob dichiarati in `sources`;
3. unisce i file YAML in una configurazione interna;
4. valida struttura, tipi, identificatori e riferimenti;
5. verifica l'autenticazione di GitHub CLI;
6. legge lo stato corrente del repository;
7. calcola le risorse da creare o aggiornare;
8. applica le modifiche nell'ordine corretto;
9. produce un riepilogo finale.

L'ordine tipico è: impostazioni, label, milestone, collaboratori, branch e infine
issue. In questo modo ogni dipendenza esiste prima di essere utilizzata.

## Modalità dry run

La modalità `--dry-run` non modifica GitHub. Mostra invece:

- file caricati;
- errori di validazione;
- risorse che verrebbero create;
- risorse che verrebbero aggiornate;
- riferimenti mancanti;
- comandi o richieste GitHub previste.

È consigliabile eseguire sempre un dry run prima di applicare una configurazione
su un repository condiviso.

## Idempotenza

RepoForge associa ogni risorsa dichiarativa alla relativa risorsa GitHub.

Per le issue, l'associazione può essere memorizzata nel body tramite un commento
HTML invisibile:

```html
<!-- repoforge:id=auth-login -->
```

Le esecuzioni successive cercano questo identificatore e aggiornano la stessa
issue. Il titolo può quindi cambiare senza creare duplicati.

## Validazione

Prima di contattare GitHub, RepoForge dovrebbe verificare almeno:

- sintassi dei file YAML;
- presenza dei campi obbligatori;
- unicità degli identificatori;
- formato dei colori;
- formato delle date;
- valori ammessi per stato e permessi;
- esistenza delle label e milestone referenziate;
- esistenza delle issue indicate come dipendenze;
- assenza di dipendenze circolari.

Un errore di validazione interrompe l'esecuzione prima di qualsiasi modifica.

## Gestione degli errori

Lo script termina con un codice diverso da zero quando:

- una dipendenza locale non è disponibile;
- GitHub CLI non è autenticata;
- il repository non esiste o non è accessibile;
- la configurazione non è valida;
- una richiesta GitHub fallisce.

Le operazioni completate prima di un errore potrebbero essere già state
applicate. Una nuova esecuzione è sicura grazie al comportamento idempotente.

## Sicurezza

- Non inserire token GitHub nei file YAML.
- Autenticarsi esclusivamente tramite `gh auth login` o variabili d'ambiente
  previste da GitHub CLI.
- Non salvare secret in chiaro nel repository.
- Usare `--dry-run` prima di modifiche massive.
- Proteggere i file contenenti configurazioni sensibili tramite `.gitignore`.

Per gestire GitHub Actions Secrets, il YAML dovrebbe contenere soltanto il nome
della variabile d'ambiente da leggere:

```yaml
secrets:
  - name: DEPLOY_TOKEN
    from_env: REPOFORGE_DEPLOY_TOKEN
```

## Limiti

- Alcune impostazioni richiedono privilegi amministrativi.
- Le funzionalità disponibili possono variare tra repository personali e
  organizzazioni.
- Alcune protezioni dei branch dipendono dal piano GitHub.
- I secret possono essere creati o aggiornati, ma non letti nuovamente tramite
  API.
- La rimozione automatica di risorse non più presenti nel YAML dovrebbe essere
  disabilitata per impostazione predefinita e attivata soltanto con un'opzione
  esplicita come `--prune`.

## Sviluppo

Controllo sintattico dello script:

```bash
bash -n repoforge.sh
```

Analisi statica con ShellCheck:

```bash
shellcheck repoforge.sh
```

Test della configurazione:

```bash
./repoforge.sh --dry-run repoforge.yaml
```

## Licenza

Distribuito sotto licenza MIT. Consultare il file `LICENSE` per i dettagli.
