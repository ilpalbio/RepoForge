# RepoForge

RepoForge sincronizza la configurazione di un repository GitHub partendo da
file YAML versionabili. Label, milestone e issue possono essere dichiarate nel
repository insieme alle relative relazioni, quindi validate e applicate con un
solo comando.

L'unica interfaccia pubblica dell'applicazione è `repoforge.sh`. Gli script
interni non devono essere richiamati direttamente: servono a mantenere
l'applicazione modulare e a testarne separatamente i componenti.

## Funzionalità

RepoForge gestisce:

- label;
- milestone;
- issue;
- stato aperto o chiuso delle issue;
- assegnatari;
- riferimenti delle issue a label e milestone;
- dipendenze native GitHub tra issue;
- controllo dell'autenticazione e dei permessi;
- validazione preventiva della configurazione;
- dry run senza modifiche remote;
- riepilogo conclusivo della sincronizzazione.

La sincronizzazione è idempotente: applicando più volte la stessa
configurazione, RepoForge lascia invariate le risorse già allineate invece di
creare duplicati.

RepoForge non elimina automaticamente label, milestone o issue non dichiarate.
Le dipendenze delle issue gestite vengono invece sincronizzate esattamente:
quelle non più presenti nella configurazione vengono rimosse.

## Requisiti

Per l'esecuzione diretta sono richiesti:

- Bash 4.3 o successivo;
- GitHub CLI;
- `jq`;
- `yq` v4;
- accesso di rete a GitHub;
- permesso amministrativo sul repository da configurare.

Le dipendenze possono essere installate tramite il comando principale:

```bash
chmod +x repoforge.sh
./repoforge.sh install
```

Il comando rileva Homebrew o uno dei package manager Linux supportati. Su Linux
installa il binario ufficiale di `yq` v4 adatto all'architettura corrente.

Con Docker non è necessario installare queste dipendenze sulla macchina host:
vengono incluse nell'immagine.

## Autenticazione GitHub

Durante `apply`, RepoForge verifica che GitHub CLI sia autenticato e che
l'utente disponga del permesso richiesto sul repository.

Se l'esecuzione avviene in un terminale interattivo e non esiste ancora una
sessione, viene avviato automaticamente il flusso:

```text
gh auth login
```

RepoForge non legge né salva token nei file YAML. Le credenziali restano sotto
la gestione di GitHub CLI.

## Struttura del progetto

Una configurazione tipica ha questa struttura:

```text
.
├── repoforge.sh
├── repoforge.yaml
└── config/
    ├── labels.yaml
    ├── milestones.yaml
    └── issues.yaml
```

Il nome fisico dei file è libero. È la sezione `sources` del manifest a
stabilire cosa deve essere caricato. La chiave logica corretta per le issue è
sempre `issues`.

## Manifest principale

`repoforge.yaml` definisce la versione del formato, il repository predefinito e
i file sorgente:

```yaml
version: 1

repository:
  owner: acme
  name: example-project

sources:
  labels: config/labels.yaml
  milestones: config/milestones.yaml
  issues: config/issues.yaml
```

I percorsi sono relativi alla directory del manifest.

Una sorgente può anche essere una lista di file o pattern glob:

```yaml
sources:
  issues:
    - config/issues/*.yaml
    - config/backlog/*.yaml
```

Quando più file dichiarano la stessa collezione, gli elementi vengono uniti
nella configurazione interna.

## Identificatori stabili

Label, milestone e issue utilizzano un campo `id` stabile:

```yaml
id: priority-high
```

Gli ID:

- devono essere univoci nel proprio tipo di risorsa;
- possono contenere lettere minuscole, numeri e trattini;
- vengono usati per creare riferimenti tra le risorse;
- non dovrebbero cambiare dopo la prima sincronizzazione.

RepoForge inserisce un marker invisibile nelle milestone e nelle issue gestite.
Questo permette di riconoscerle tramite ID anche se il titolo viene modificato.

## Configurare le label

Esempio di `config/labels.yaml`:

```yaml
labels:
  - id: priority-high
    name: priority:high
    description: Intervento ad alta priorità
    color: D73A4A

  - id: type-bug
    name: type:bug
    description: Comportamento inatteso
    color: B60205
```

Il colore deve contenere esattamente sei caratteri esadecimali, senza `#`.

Durante la sincronizzazione:

- una label assente viene creata;
- una label differente viene aggiornata;
- una label già allineata rimane invariata;
- una label remota non dichiarata non viene eliminata.

## Configurare le milestone

Esempio di `config/milestones.yaml`:

```yaml
milestones:
  - id: release-v1
    title: Release 1.0
    description: Prima versione stabile
    due_on: 2026-08-31
    state: open
```

`due_on` usa il formato `YYYY-MM-DD`. Gli stati ammessi sono:

- `open`;
- `closed`.

RepoForge sincronizza titolo, descrizione, scadenza e stato. Le milestone remote
non dichiarate non vengono eliminate.

## Configurare le issue

Esempio di `config/issues.yaml`:

```yaml
issues:
  - id: implement-authentication
    title: Implementare l'autenticazione utente
    body: |
      Aggiungere login, logout e gestione della sessione.

    assignees: []

    labels:
      - type-feature
      - priority-high

    milestone: release-v1

    dependencies:
      - setup-project

    state: open
```

I campi `labels`, `milestone` e `dependencies` contengono ID RepoForge, non i
nomi o i numeri visualizzati su GitHub.

RepoForge risolve automaticamente:

- ID label nel nome GitHub corrispondente;
- ID milestone nel numero GitHub corrispondente;
- ID issue nel numero e nell'identificatore GitHub necessari alle dipendenze.

Gli assegnatari sono username GitHub:

```yaml
assignees:
  - octocat
```

Prima di applicare le dipendenze, tutte le issue vengono create o aggiornate.
Questo secondo passaggio permette di stabilire relazioni anche tra issue create
nella stessa esecuzione.

## Validazione

Validare la configurazione senza contattare GitHub:

```bash
./repoforge.sh validate repoforge.yaml
```

La validazione controlla, tra le altre cose:

- sintassi YAML e JSON interno;
- presenza e tipo delle sezioni principali;
- file e glob dichiarati nel manifest;
- campi obbligatori;
- formato e unicità degli ID;
- formato dei colori;
- formato delle date;
- stati ammessi;
- label e milestone referenziate;
- dipendenze verso issue esistenti;
- dipendenze di una issue verso sé stessa.

Qualsiasi errore interrompe l'esecuzione prima di contattare GitHub.

## Dry run

Mostrare le risorse dichiarate senza modificare GitHub:

```bash
./repoforge.sh --dry-run repoforge.yaml
```

Il dry run mostra:

- repository di destinazione;
- numero di label;
- numero di milestone;
- numero di issue aperte e chiuse;
- numero di assegnazioni;
- numero di dipendenze.

È possibile sovrascrivere il repository del manifest:

```bash
./repoforge.sh --dry-run repoforge.yaml \
  --repo altra-organizzazione/altro-repository
```

## Applicare la configurazione

Eseguire la sincronizzazione completa:

```bash
./repoforge.sh apply repoforge.yaml
```

Applicarla a un repository diverso da quello nel manifest:

```bash
./repoforge.sh apply repoforge.yaml \
  --repo acme/example-project
```

Il flusso eseguito è:

1. caricamento del manifest e dei file sorgente;
2. unione della configurazione;
3. validazione completa;
4. verifica dell'autenticazione;
5. verifica del permesso amministrativo;
6. sincronizzazione delle label;
7. sincronizzazione delle milestone;
8. creazione o aggiornamento delle issue;
9. applicazione di stato, assegnatari e dipendenze;
10. riepilogo e verifica conclusiva.

Se un passaggio fallisce, quelli successivi non vengono eseguiti.

## Riepilogo finale

Al termine di `apply`, RepoForge confronta le risorse configurate con quelle
presenti su GitHub e mostra un riepilogo:

```text
Riepilogo RepoForge
===================
  Repository               acme/example-project
  Label sincronizzate      5/5
  Milestone sincronizzate  5/5
  Issue sincronizzate      5/5
  Issue aperte             4
  Issue chiuse             1
  Assegnazioni dichiarate  0
  Dipendenze dichiarate    5

[repoforge.sh] Sincronizzazione completa.
```

Se una risorsa configurata non viene trovata su GitHub, il riepilogo la elenca
e il comando termina con un codice diverso da zero.

## Utilizzo con Docker

### Costruire l'immagine

Lo stage finale include dipendenze, configurazione e applicazione:

```bash
docker build \
  --target repoforge \
  -t repoforge .
```

La distribuzione predefinita è Ubuntu 24.04. È possibile cambiarla:

```bash
docker build \
  --build-arg UBUNTU_VERSION=24.04 \
  --target repoforge \
  -t repoforge .
```

### Validare con Docker

```bash
docker run --rm repoforge \
  validate repoforge.yaml
```

### Eseguire il dry run con Docker

```bash
docker run --rm repoforge \
  --dry-run repoforge.yaml \
  --repo acme/example-project
```

### Applicare con Docker

L'autenticazione interattiva richiede `-it`:

```bash
docker run --rm -it \
  repoforge \
  apply repoforge.yaml \
  --repo acme/example-project
```

Il container viene rimosso al termine, quindi senza un volume anche la
configurazione GitHub CLI viene eliminata.

### Conservare l'autenticazione

Creare una volta un volume:

```bash
docker volume create repoforge-gh-config
```

Usarlo durante l'applicazione:

```bash
docker run --rm -it \
  -v repoforge-gh-config:/root/.config/gh \
  repoforge \
  apply repoforge.yaml \
  --repo acme/example-project
```

Alla prima esecuzione GitHub CLI richiede il login. Le esecuzioni successive
riutilizzano la sessione memorizzata nel volume.

### Usare una configurazione esterna

L'immagine contiene la configurazione presente al momento della build. Per
usare file locali senza ricostruire l'immagine, montare una directory:

```bash
docker run --rm -it \
  -v repoforge-gh-config:/root/.config/gh \
  -v "$PWD/my-config:/workspace/config:ro" \
  repoforge \
  apply /workspace/config/repoforge.yaml \
  --repo acme/example-project
```

Tutti i percorsi in `sources` devono essere relativi al manifest montato.

## Codici di uscita

RepoForge restituisce `0` quando il comando termina correttamente.

Restituisce un codice diverso da zero quando, per esempio:

- manca una dipendenza locale;
- il manifest non esiste;
- un YAML non è valido;
- la configurazione non supera la validazione;
- GitHub CLI non riesce ad autenticarsi;
- l'utente non possiede i permessi richiesti;
- una chiamata GitHub fallisce;
- una risorsa referenziata non esiste;
- il riepilogo rileva una sincronizzazione incompleta.

Questo comportamento permette di usare RepoForge anche in pipeline CI.

## Sicurezza

- Non inserire token, password o secret nei file YAML.
- Usare il sistema di autenticazione di GitHub CLI.
- Non copiare credenziali dentro l'immagine Docker.
- Montare la configurazione GitHub CLI tramite volume quando serve persistenza.
- Revisionare sempre il dry run prima di applicare modifiche importanti.

## Limiti attuali

- RepoForge non elimina automaticamente label, milestone o issue assenti dalla
  configurazione.
- La rimozione delle dipendenze è invece parte della loro sincronizzazione.
- Gli assegnatari devono essere utenti GitHub validi e assegnabili al
  repository.
- Le funzionalità disponibili possono dipendere dal piano GitHub e dai permessi
  del token.

## Licenza

Consultare il file `LICENSE`.
