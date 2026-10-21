---
name: karr-core
description: Use when working on App::karr itself — the refs-first board storage under refs/karr/*, the Task and Config model, the command layer, the Git transport, the encoding boundary and the karr-foundation subsystem.
---

# karr — Kern

`App::karr` ist die Perl-Neuschreibung von [kanban-md](https://github.com/antopolskiy/kanban-md):
ein dateibasiertes Kanban-Board für Multi-Agent-Arbeit. Diese Skill ist die Landkarte der
**Distribution selbst** — wie das Board auf der Platte liegt, welche Schicht wen ruft, welche
Datei wofür zuständig ist und wo es erfahrungsgemäß klemmt. Sie ist **nicht** die Bedienungs-
anleitung: das Board *benutzen* (Karten anlegen, aufnehmen, abgeben) steht in
`kanban-issues-karr-coordination`, eine zugewiesene Karte abarbeiten in
`kanban-issues-karr-ticket`, karr-foundation in `karr-foundation-cli`.

## Der Zustand liegt in Git-Refs

Das Board ist der Namensraum `refs/karr/*` im Repository. Nichts davon landet im Arbeitsbaum.

| Ref | Inhalt |
|---|---|
| `refs/karr/config` | die *sparse* Overrides der Board-Konfiguration — nur, was vom Default abweicht |
| `refs/karr/tasks/<ID>/data` | eine Karte: YAML-Frontmatter plus Markdown-Body |
| `refs/karr/meta/next-id` | der Zähler, aus dem die Karten-IDs vergeben werden |
| `refs/karr/meta/board-id` | die Identität des Boards — der Schutz gegen einen vertauschten Remote |
| `refs/karr/meta/encoding` | Marker, dass die Payloads der Encoding-Regel folgen (alte Boards) |
| `refs/karr/log/<role>/<email>` | das Activity-Log, rollenqualifizierte Identität |
| `refs/karr-local/deleted/` | Tombstones gelöschter Refs, die noch nicht veröffentlicht sind |
| `refs/karr-foundation/*` | Chain, Run-Logs und Question-Mailbox von karr-foundation — **eigener** Namensraum |

Ein Ref trägt die Karte als Blob: `git show refs/karr/tasks/12/data` liest sie. `tasks/` mit
seiner `config.yml` ist die **materialisierte Sicht** — von `karr materialize` geschrieben, von
`karr import --yes` zurückgelesen, eine Brücke für kanban-md-Interop und fürs Greppen. Sie steht
in jedem Board in `.gitignore` und ist nie die Quelle der Wahrheit.

## Die Karte

Frontmatter (YAML::XS) plus Markdown-Body, 100 % kompatibel zu kanban-md. Modelliert sind
`id`, `title`, `status`, `priority`, `class`, `assignee`, `tags`, `due`, `estimate`,
`depends_on`, `blocked`, `block_reason`, `claimed_by`, `claimed_at`, `created`, `updated`,
`started`, `completed`, `body`. Was karr nicht modelliert, wandert nach `extra` und übersteht
einen Schreibvorgang unverändert — kanban-md verwirft unbekannte Felder, karr nicht, weil das
verworfene Feld genauso gut eine handgeschriebene Notiz sein kann.

Zwei Fallen im Frontmatter:

- **`needs:` ist kein Feld, sondern ein Tag.** Der Quer-Board-Verweis auf eine Karte eines
  anderen Repos steht als Tag `needs:<board>#<id>` auf der wartenden Karte
  (`App::karr::CrossBoard`). `karr needs --resolve` trägt ihn ab, wenn die ferne Karte terminal
  ist — terminal heißt *geschlossen*, nicht *erfolgreich*.
- **`parent` ist bewusst kein Konzept.** Das Feld round-trippt durch `karr import`, aber kein
  karr-Kommando setzt, filtert, rendert oder sortiert es. Hierarchie bleibt bei kanban-md.

`claimed_by` ist eine **aktive Lease**, keine Autorschaft: sie verfällt (`claim_timeout`), und
auf einer terminalen Karte (`done`, `archived`) bewacht sie nichts mehr — bleibt aber als
Provenienz in `karr show` und in jedem `--json`-Payload sichtbar.

## Die Konfiguration

`App::karr::Config->default_config` ist der Startpunkt jedes Boards: die Spalten `backlog`,
`todo`, `in-progress` und `review` (die beiden letzten mit `require_claim`), `done`, `archived`;
die Prioritäten `low`, `medium`, `high`, `critical`; die Klassen `expedite`, `fixed-date`,
`standard`, `intangible`; `claim_timeout` 1 h, `lock_timeout` 5 min; `foundation.enabled`; und
die Neukarte-Vorgaben `backlog` / `medium` / `standard`.

`effective_config` legt die Overrides aus `refs/karr/config` über die Defaults, und
`save_config` schreibt **nur** die Differenz zurück — ein Board, das `lock_timeout` nie
angefasst hat, trägt keine eingefrorene Kopie davon. Der Zähler `next_id` gehört **nicht** in
die Config, sondern in `refs/karr/meta/next-id`; `materialize` kopiert ihn in die Datei-Sicht
(kanban-md verlangt `next_id >= 1`), `import` lässt ihn dort wieder fallen.

## Die Schichten

```
bin/karr  →  App::karr (MooX::Cmd-Wurzel)  →  Cmd/*.pm  →  Role/BoardAccess
                                        →  Role/BoardDiscovery + Role/SyncLifecycle
                                        →  BoardStore  →  Git  →  Git::Native (libgit2)
```

- **`Cmd/*.pm`** — je ein Unterkommando; `MooX::Cmd` löst den Namensraum auf, `MooX::Options` die
  Optionen. Kein `namespace::clean` in den Kommandoklassen — inkompatibel mit MooX::Options.
- **`Role/BoardAccess`** — die Tür, durch die jedes Kommando geht: Discovery (Git-Repo, Store,
  Config), Sync-Lifecycle und der Task-Zugriff. `t/133-boardaccess-write-doors.t` hält fest,
  welche Kommandos durch diese Tür schreiben dürfen.
- **`Role/SyncLifecycle`** — der Schreibweg: pull, dann push, mit bis zu drei Versuchen (der
  erste still, die Wiederholungen ab dem zweiten angesagt). Ein Ref, den die Gegenseite
  zurückwies, wird **nicht** wiederholt — die Gegenseite hat geantwortet; nur eine Kontention
  (zwei Pushes auf dieselbe Ref) gewinnt der nächste Versuch.
- **`Role/SyncGuard`** — die Versicherung: endet ein Schreibkommando mit einem Fehler, wird der
  lokale Stand trotzdem gepusht, damit kein Board-Stand verloren geht.
- **`BoardStore`** — die Ref-Persistenz: `load_tasks`, `save_task`, `effective_config`,
  `allocate_next_id`, `materialize_to`, `serialize_from`.
- **`Git`** — der Transport. Lokal nativ über `Git::Native` (libgit2), für den Remote-Transport
  ein git-CLI-Fallback, weil libgit2 kein `~/.ssh/config` liest: `Host`-Alias, `ProxyCommand`
  und `ssh://`-URLs wirken nur über die CLI.
- **`Task`** — eine Karte: YAML-Frontmatter plus Markdown-Body, lesen und schreiben.
- **`Encoding`** — die Zeichen/Oktett-Grenze: argv, Std-Handles, Ref-Blobs, YAML, JSON. Nichts
  außerhalb dieser Datei darf `Encode::encode`/`decode`, `YAML::XS::Dump`/`Load` oder
  `encode_json`/`decode_json` direkt benutzen — innen sind es Zeichen, nur an den Rändern Oktett.
- **`App::karr::Error`** — macht aus internen Fehlern eine einzige saubere Zeile für den Nutzer.

## Die Kommandos

`init`, `create`, `list`, `show`, `board`, `dashboard`, `move`, `edit`, `delete`, `pick`,
`unlock`, `archive`, `handoff`, `needs`, `destroy`, `config`, `disable`, `enable`, `context`,
`log`, `metrics`, `backup`, `restore`, `materialize`, `import`, `repair`, `sync`, `agent-name`,
`skill`, `set-refs`, `get-refs`, `completion`.

Jedes mutierende Kommando zieht vorher und schiebt danach. `create` landet in `backlog`,
unbeansprucht; `backlog` wird weder von `pick` noch von karr-foundation herausgegeben, und die
Beförderung dorthin ist Sache der Maintainer. Der vollständige Aufrufsrahmen steht in
`kanban-issues-karr-coordination` — hier zählt, **welche** Kommandos es gibt.

Der Exit-Code-Vertrag (ADR 0002): `0` Erfolg, `1` Laufzeitfehler, `2` Aufruffehler. Bei einem
Aufruffehler steht die Antwort **hinten**, nach dem Usage-Block — die Diagnose wird von `tail -n`
abgeschnitten, und karrs Hauptleser sind Agenten.

## Die Fallstricke

- **Ein Board braucht ein Git-Repo.** `karr` in einem Verzeichnis ohne Repository bricht mit
  `Not a git repository. karr requires Git.` ab.
- **Ein veralteter `next-id` überschreibt still eine Karte.** `refs/karr/meta/next-id` ist die
  einzige Autorität für die ID-Vergabe; steht sie hinter einer vergebenen ID, vergibt `karr
  create` diese ID erneut — und `save_task` schreibt **ohne** Compare-and-swap, die Karte ist
  weg. `karr import` zieht den Zähler nicht mit; `ensure_next_id` und `serialize_from` setzen
  eine Untergrenze. Nach `create` die ID gegenchecken.
- **`sync --push` braucht Zugangsdaten.** libgit2 zieht den SSH-Key aus dem Agenten oder
  `~/.ssh/id_ed25519`/`id_rsa`, ein HTTPS-Board aus einem Token; ein `~/.ssh/config` mit
  `Host`-Alias oder `ProxyCommand` erreicht libgit2 nicht, dafür gibt es den CLI-Fallback.
  `BatchMode=yes` heißt: keine interaktive Passphrase — ein Agent ohne Key bekommt einen Fehler,
  keine Nachfrage.
- **Der Push prunt nicht.** Eine Remote-Ref, die der Clone nie gesehen hat, ist die Karte eines
  anderen Agenten; sie zu löschen, verliert sie ganz.
- **Board-Mutationen bei Fächer-Ausgabe serialisieren.** Jedes schreibende Kommando zieht und
  schiebt; N davon gleichzeitig sind ein Ressourcenereignis. Karten einzeln übergeben, eigene
  Züge nacheinander.
- **`pick` ist der einzige exklusive Pfad.** Der Lock-Ref serialisiert Agenten, kann sie aber
  nicht binden — sein Inhaber ist die `user.email` des Clones, die auf einer Maschine alle
  teilen. Der Compare-and-swap sitzt deshalb auf der Karte selbst (`save_task_cas`), nicht auf
  dem Lock.
- **`Role::ExitCodes`** sortiert Aufruffehler auf Code 2 und hängt die Diagnose hinter den
  Usage-Block.

## karr-foundation

Der zweite Einstiegspunkt: `bin/karr-foundation` fährt Agenten-Läufe über mehrere Boards in
Unterverzeichnissen. `App::karr::Foundation` ist der Single-Shot-Daemon, daneben `Overview`
(read-only), `Picker`, `Runner`, `Agents`, `State` (Lock, JSON-State, Cooldown), `Limits`,
`ChainStore` (`refs/karr-foundation/*`), `Executor`, `Questions` (Mailbox) und `Coordinator` —
die Urteilsschicht, ein Agent wie die anderen, aber nie im heißen Pfad: er läuft nur bei
Abweichung (ADR 0002). Die drei Schichten der Flotte: **Koordination** ist geteilt (Karten,
Abhängigkeiten, Chain, Fragen liegen in Git-Refs), **Ausführung** ist lokal (welche
Agenten-Kommandos es hier gibt, ob sie funktionieren, wie viele laufen dürfen), **Urteil** ist
ein Agent. Ein **Disabled board** hat `foundation.enabled = 0` in `refs/karr/config` —
Board-Zustand, kein Maschinenzustand, er synct mit und schlägt jedes `--command` und
`claude: true`; `--force` hebt ihn nicht auf. Bedienung und Agenten-Verträge: Skill
`karr-foundation-cli`.

## Tests

```bash
prove -l t/                 # die ganze Suite
prove -l t/01-task.t        # eine Datei
dzil test                   # Dist::Zilla
dzil build                  # Bauen
```

Die Suite läuft offline gegen die Helfer unter `t/lib/` (`TestGit`, `MockStore`, `TestEnv`,
`TestKarr`, `TestShell`) — kein Netzzugriff, kein Live-Board. `t/` ist nummeriert und wächst mit
dem Ticket: `t/100`–`t/1xx` sind die Regressionen, die zu einer Karte entstanden sind.

## Grenzen

- karr verwaltet ein Board; **Arbeit ausführen** ist nicht seine Sache — das ist karr-foundation.
- Die Feature-Parität zu kanban-md gilt für das Board. Refs-first-Speicherung, Quer-Board-
  Abhängigkeiten und karr-foundation haben dort **kein** Gegenstück und keine Paritätspflicht.
- `parent`/Subtask bleibt bewusst außen vor.
