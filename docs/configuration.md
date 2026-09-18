# Configuration

Le README dit comment se servir de l'usine. Ce fichier dit ce que chaque clé fait.


Toute la configuration est lue par `conf_get`/`conf_require` (`bin/lib.sh`)
ou par `factory.mk`, jamais codee en dur : c'est le point de l'extraction,
aucune valeur d'infrastructure Brume ne doit rester dans les scripts (voir
`tests/hygiene.test.sh`).

`conf_get NOM [defaut]` cherche d'abord `$NOM` dans l'environnement du
process, puis `factory.conf`, puis `.env`, a la racine du depot resolue par
`factory_root()` (`$FACTORY_ROOT`, sinon `$CLAUDE_PROJECT_DIR`, sinon
le parent du repertoire git COMMUN — l'arbre principal, meme depuis un worktree de
carte — sinon le repertoire courant). `conf_require`
fait la meme chose mais sort en code 3 si la valeur manque.

**Sans exception.** Les labels `factory:*` en étaient une jusqu'au modèle de
release : ils étaient lus par expansion directe de l'environnement du process, si
bien que les poser dans `factory.conf` ne suffisait pas — et rien ne le disait à
l'exécution. Le paragraphe « Défaut connu, à corriger » qui décrivait ça est
parti avec le défaut : **les sept noms passent par `label_get` (`bin/lib.sh`)**,
qui appelle `conf_get` et porte le défaut de chaque label à un seul endroit.

`bin/gh-security-triage.py` est le seul lecteur qui ne puisse pas sourcer
`bin/lib.sh` — il est en Python. Ce n'est pas une exception pour autant : son
appelant résout les rôles par `label_get` et lui passe les six qu'il lit —
`PRIO`, `BUSY`, `DONE`, `STAGED` exigés (sortie en 3 si l'un manque),
`BLOCKED` et `HUMAN` facultatifs (absents, les cartes bloquées ou en arbitrage
ne sont pas gelées, et c'est dit) —, ce que `factory.mk` fait, et le Python les
lit **strictement** — aucun défaut à lui. Un défaut
écrit côté Python serait un second domicile pour le nom, invisible depuis
`factory.conf` : le renommage marcherait dans les scripts shell et pas là, et le
triage poserait sa priorité sous l'ANCIEN nom — une carte de sécurité hors de la
file, sans que rien ne le dise.

**Deux branches nommées, et elles ne disent pas la même chose.** `FACTORY_TRUNK`
est la branche de **production** et `FACTORY_STAGING` la branche de **travail**
(validée, le client y teste). La boucle n'écrit sur aucune des deux : Pony
pousse sur `feature/*`, EVA seule merge une feature dans la branche de travail
et sort la branche de travail en production, sur un ordre humain tracé. Les
scripts qui nomment une branche appellent `branches_require` (`bin/lib.sh`),
qui les résout, rogne leurs blancs, réapplique les défauts et **refuse de
démarrer en code 3 si les deux sont la même** — une feature mergée irait
directement en production. Le pourquoi est dans [`docs/release.md`](release.md).

| Cle | Defaut | Lue via | Consommateur |
|---|---|---|---|
| `GH_REPO` | *(requise)* | `conf_get`/`conf_require` ; `factory.mk` la lit par `conf_get` et l'exporte pour le tour | `gh-next-issue.sh`, `gh-feature.py`, `feature-up.sh`, `deliver.sh`, `gh-comment.sh`, `gh-unblock.sh`, `gh-seed-labels.sh`, `gh-release.sh`, `wt-cleanup.sh`, `gh-pr-attention.sh`, `run-loop.sh`, `deploy.sh`, `bin/factory stop`, garde de `factory.mk` |
| `FACTORY_TRUNK` | `main` | `conf_get`, via `branches_require` | la branche de **PRODUCTION**, cible de la release. **Pony n'y écrit jamais ; seule EVA y écrit, par `bin/eva-release.sh`, sur un ordre humain tracé (v2).** Lue par `bin/lib.sh` (la garde), `bin/gh-release.sh` (le tag à partir duquel les features sont fermées) et `bin/eva-release.sh` (la cible du merge de release) — et par personne d'autre. Son NOM, en revanche, **est** dans l'environnement de l'agent : `branches_require` exporte la paire normalisée, et `factory.mk` l'appelle dans le shell même qui lance l'agent (le pourquoi de cet export est écrit dans `bin/lib.sh`). Ce n'est pas un trou : ce qui protège la production, c'est que seule EVA y écrit, sur un ordre tracé — pas l'ignorance de son nom, et pas non plus une protection de branche, absente par défaut (v2, § 3) |
| `FACTORY_STAGING` | `staging` | `conf_get`, via `branches_require` | la branche de **TRAVAIL** — celle que la release relit, que l'environnement en ligne suit, et que le client teste. **L'usine n'y écrit pas** : Pony pousse sur `feature/*`, EVA seule y merge une feature relue (v2, § 3). Ce qu'elle gouverne : la base par défaut d'une branche de feature et la cible de sa PR (`feature-up.sh`, sauf pile sur `feature/<G>`), la garde de branche et le `fetch`/`merge --ff-only` de `factory.mk`, le `checkout --force -B` de `deploy.sh`. Jamais lue par une variable Make |
| `FACTORY_SECURITY_FEATURE` | *(vide)* | `conf_get` ; `factory.mk` la résout et la passe au triage | **la feature permanente des cartes d'alerte** — le numéro d'une issue de type Feature, ouverte. Posée, `gh-security-triage.py` rattache chaque carte qu'il **crée** comme sous-issue de cette feature (`addSubIssue`, le node id lu une fois par tour ; un rattachement refusé pose `needs-human` sur la carte neuve ; les cartes d'alerte créées AVANT la clé restent orphelines, à rattacher à la main), `eva-watch.sh` y lit les cartes d'alerte ouvertes (source g : un ping par alerte critical/high, le compte par sévérité en `--etat` ; une source illisible se dégrade, elle ne tue pas la vigie), et **`gh-release.sh` / `eva-release.sh` la tiennent hors des règles de release** : ses cartes sorties sont commentées, `factory:staged` retiré, elle n'est ni fermée (fermée, le triage sortirait en 3 à chaque tour) ni bloquante (une alerte ouverte n'empêche pas de sortir un correctif). Vide : chaque carte d'alerte est sa propre mini-feature — une branche, une PR, un merge d'EVA et une ligne de release **par alerte** —, le triage le dit à chaque tour, et la vigie reconnaît les cartes à la marque `<!-- factory-security:… -->`. Une feature fermée ou qui n'est pas une Feature : 3, aucune carte créée ; illisible par un raté passager : 4, retenté |
| `FACTORY_MILESTONE` | *(vide = aucun filtre)* | `conf_get` | `gh-next-issue.sh`, et personne d'autre : **le jalon nomme la release et le sondage le fait respecter**. Filtrage côté client sur le champ `milestone` déjà présent dans la réponse — aucun appel de plus. Vide signifie *aucun filtre*, pas « jalon sans nom » |
| `FACTORY_GIT_NAME` | *(requise)* | `conf_get`/`conf_require`, au demarrage de `make loop` | `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME` exportes par `factory.mk` avant chaque tour |
| `FACTORY_GIT_EMAIL` | *(requise)* | idem | `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` idem |
| `FACTORY_HUMAN_LOGIN` | *(requise)* | `conf_get`/`conf_require` | `gh-pr-attention.sh` (chaque remarque de ce login sur une PR de feature ouverte — review, conversation, ligne — devient une carte sous la feature), `eva-merge.sh` (son *approve* sur la tête courante vaut ordre de merge ; son « changes requested » l'annule), `eva-watch.sh` (une PR est « à relire » tant qu'il ne l'a pas approuvée sur sa tête) et le canal de confiance du skill `orchestrateur` |
| `FACTORY_BOT_LOGIN` | *(requise)* | `conf_require`/`conf_get` | `gh-pr-attention.sh` : le login sous lequel l'usine PARLE. C'est sa réponse dans le fil (« → #carte », marquée) qui dit qu'une remarque a été transformée — sans défaut possible, une valeur fausse ferait retransformer chaque remarque à chaque tour |
| `FACTORY_BUSY_LABEL` | `factory:in-progress` | `conf_get`, via `label_get busy` | `gh-next-issue.sh`/`gh-feature.py` (la carte prise passe devant : c'est le tour interrompu, son répertoire de tour l'attend), posé et retiré par `card-state.sh busy`/`unbusy` (l'orchestrateur ne nomme aucun label), `gh-security-triage.py` (`FROZEN`, spec gelee) |
| `FACTORY_BLOCKED_LABEL` | `factory:blocked` | `conf_get`, via `label_get blocked` | `gh-next-issue.sh` (exclu de la file), `gh-unblock.sh` (retire quand le bloqueur tombe) |
| `FACTORY_HUMAN_LABEL` | `factory:needs-human` | `conf_get`, via `label_get human` | label « décision humaine requise, hors file » : lu par `gh-next-issue.sh` (la carte est écartée), posé par `card-state.sh needs-human` (l'orchestrateur, `feature-up.sh` et `deliver.sh` sur un refus de carte, `gh-pr-attention.sh` sur une carte non rattachée) — avec la raison en commentaire et le marqueur de remise à zéro du tour |
| `FACTORY_EPIC_LABEL` | `factory:epic` | `conf_get`, via `label_get epic` | `gh-next-issue.sh` (exclu de la file : chapeau d'epopee, pas du travail) |
| `FACTORY_DONE_LABEL` | `factory:delivered` | `conf_get`, via `label_get done` | `gh-security-triage.py` (`FROZEN`) seulement : **depuis la v2 ce n'est plus un label de carte** — une carte livrée est fermée par `deliver.sh`, et `gh-next-issue.sh` ne le lit plus |
| `FACTORY_STAGED_LABEL` | `factory:staged` | `conf_get`, via `label_get staged` | **un label de FEATURE (v2)** : intégrée à la branche de travail, attend la release. Lu par `gh-dependencies.py` (un bloqueur qui le porte est satisfait) et `feature-up.sh` (une feature `staged` n'est pas une base de pile) ; posé par `eva-merge.sh` au merge sur ordre humain, exigé par `eva-release.sh` (sans lui, la feature bloque la release), retiré par `gh-release.sh`. Plus lu sur les cartes |
| `FACTORY_PRIORITY_LABEL` | `factory:priority` | `conf_get`, via `label_get priority` | `gh-next-issue.sh`/`gh-feature.py` (sur la carte : passe devant ; sur la feature : ses cartes passent devant celles des autres features), pose par `card-state.sh priority` (la refacto carvée par l'orchestrateur), `gh-security-triage.py` et `gh-pr-attention.sh` sur les cartes qu'ils creent |
| `FACTORY_IN_LOOP` | *(vide ; posée à `1` par `factory.mk` seulement)* | environnement direct | **Ce n'est pas une clé de configuration, et personne ne la pose à la main** : c'est le marqueur que la boucle exporte et que `gh-release.sh`, `eva-merge.sh` et `eva-release.sh` lisent pour sortir en 3 : les gestes d'EVA ne se font jamais depuis un tour. Il rend exécutable « la release est un geste humain » — sans lui, un agent qui hérite de `GH_TOKEN` fermerait des cartes que personne n'a relues |
| `FACTORY_STATE` | `/srv/factory` | `conf_get` | racine du volume persistant de l'usine : `push-env.sh`, `run-loop.sh`, `status.sh`, `deploy.sh`, `bin/factory stop`, fallback du chemin de `GH_APP_KEY` |
| `FACTORY_REPO_DIR` | `$FACTORY_STATE/workspace/<basename de GH_REPO>` | `conf_get` | `run-loop.sh`, `deploy.sh`, `bin/factory stop` : chemin du depot sur la machine. `eva-watch.sh` (repli d'EVA) : où lire `.omc/loop.halt` et `.omc/loop.file-vide` quand `$FACTORY_ROOT` n'a pas de `.omc` (depuis le conteneur d'EVA, `$FACTORY_ROOT` est son clone, où la boucle n'écrit jamais). Ordre : `$FACTORY_ROOT/.omc`, puis `/factory-repo/.omc` (l'arbre de la boucle, monté en lecture seule par `nix/eva.nix`), puis celui-ci |
| `FACTORY_IMAGE_TAG` | `factory:dev` | `conf_get` | `run-loop.sh` : tag de l'image devcontainer lancee par `docker run` |
| `FACTORY_CONTAINER_USER` | `vscode` | `conf_get` | `run-loop.sh` : utilisateur du conteneur (`-u`), celui dont le home recoit les authentifications d'agent |
| `FACTORY_CONTAINER_HOME` | `/home/$FACTORY_CONTAINER_USER` | `conf_get` | `run-loop.sh` : home de cet utilisateur, ou sont montes `.claude`, `.codex`, `.gemini` |
| `FACTORY_DOCKER_BIN` | *(vide = `docker` reel)* | environnement direct | `run-loop.sh` : remplace le binaire docker, utilise par les tests |
| `FACTORY_HOST` | *(requise avec `FACTORY_KEY`)* | `conf_get`/`conf_require` | `bin/lib.sh` (`factory_ssh`), `status.sh`, `deploy.sh`, `bin/factory log`/`ssh` |
| `FACTORY_KEY` | *(requise avec `FACTORY_HOST`)* | `conf_get`/`conf_require` | idem : chemin de la cle privee SSH vers l'usine |
| `FACTORY_SSH_OPTS` | *(vide)* | `conf_get`, expansion non quotee dans la commande `ssh` | `bin/lib.sh` (`factory_ssh`), `bin/factory log`/`ssh` : options `ssh` supplementaires (ex. `-o ProxyJump=...`) |
| `FACTORY_NAME` | `usine` | `conf_get` | `status.sh`, `deploy.sh` : nom affiche dans les messages |
| `FACTORY_ENV_DENY` | *(vide)* | `conf_get` | `push-env.sh` : liste blanc-separee de variables du `.env` racine qui NE traversent PAS vers l'usine (en plus du motif universel `^(PROD_|.*_SUDO_|FACTORY_(KEY|HOST|SSH_|NAS_|POOL))` — un secret de production, un sudo, ou la cle qui ouvre l'usine elle-meme) |
| `FACTORY_ENV_DENY_PATTERN` | *(vide)* | `conf_get` | `push-env.sh` : motif regex etendu supplementaire, propre au consommateur |
| `FACTORY_ENV_PATH` | `$FACTORY_STATE/secrets/env` | environnement direct (`${FACTORY_ENV_PATH:-...}`) | `push-env.sh` : chemin distant ou le `.env` compose est depose |
| `LOOP_SLEEP` | `60` | `conf_get` dans un `$(shell)` de `factory.mk`, sous `?=` : ligne de commande et environnement, puis `factory.conf`, puis `.env` | `factory.mk` : attente entre deux sondages quand la file est vide, et après un raté passager. Un entier, non vide, sinon 3 au démarrage (une valeur vide n'est pas « non définie » pour Make, et `sleep` sans opérande sondait en continu) |
| `LOOP_MAX_RETRY` | `3` | idem | `factory.mk` : le tourniquet — une carte a N tours d'affilée au plus, le (N+1)ᵉ pose `.omc/loop.halt` et sort en 4 ; chaque tour servi sur la même carte compte, qu'il ait avancé ou non ; le compteur `.omc/loop.retry` vit sur disque et se périme après un jour, évalué au démarrage. Entier, non vide, sinon 3 |
| `LOOP_PROMPT` | *(le prompt de l'orchestrateur, dans `factory.mk`)* | variable Make (`?=`) | `factory.mk` : le texte envoyé à l'orchestrateur, avec sept marqueurs substitués au lancement — `@ISSUE@` (la carte), `@REPO@`, `@FEATURE@` (le numéro de la feature), `@PR@`, `@WORKTREE@` (où l'orchestrateur est lancé), `@ROOT@` (la racine de l'arbre principal, `$(CURDIR)` : les artefacts du tour vivent sous `@ROOT@/.omc/turn/@ISSUE@/`, jamais dans le worktree) et `@BASE@` (le SHA de `origin/feature/<F>` à l'admission). Court à dessein : la procédure vit dans le skill `orchestrator` |
| `CLAUDE_LAUNCH` | `claude --dangerously-skip-permissions --model claude-opus-5 --effort low` | `conf_get` dans un `$(shell)` de `factory.mk`, sous `?=` (comme `LOOP_SLEEP`) | `factory.mk` : commande qui lance l'ORCHESTRATEUR a chaque tour, dans le worktree de la feature. L'orchestrateur est toujours Claude ; Codex est un rôle (`CODEX_ROLE_LAUNCH`). `MAIN` et `CODEX_LAUNCH` ont disparu avec la v2 |
| `FACTORY_ROLE_ANALYSTE` | `claude-opus-5` | `conf_get`, via `role_get analyste` | **le tour v2** (`docs/v2-feature.md` § 4) : modèle du rôle. `bin/role.sh` le lance sous ce modèle et prouve, dans ce que le CLI a écrit, que c'est bien lui qui a répondu ; `bin/turn-verify.sh` refuse le push si un artefact porte un autre modèle. Le CLI se déduit du préfixe (`claude-` → claude, sinon codex). Les huit rôles passent par `role_get` — jamais une lecture directe, pour la même raison que les labels |
| `FACTORY_ROLE_CODEUR` | `gpt-6-astra` | `conf_get`, via `role_get codeur` | idem |
| `FACTORY_ROLE_RELECTEUR_MAINT` | `claude-opus-5` | `conf_get`, via `role_get relecteur-maint` | idem — une autre famille que le codeur, à dessein |
| `FACTORY_ROLE_RELECTEUR_SECU` | `claude-fable-5-1` | `conf_get`, via `role_get relecteur-secu` | idem — bloquant, sans plafond |
| `FACTORY_ROLE_WRITER` | `claude-haiku-4-5-20251001` | `conf_get`, via `role_get writer` | idem — exigé seulement si l'analyste marque un comportement documenté ET que le dépôt porte `DOCS.md` |
| `FACTORY_ROLE_TEST_ENGINEER` | `claude-fable-5-1` | `conf_get`, via `role_get test-engineer` | idem — optionnel |
| `FACTORY_ROLE_DESIGNER` | `gpt-6-astra` | `conf_get`, via `role_get designer` | idem — optionnel |
| `FACTORY_ROLE_DOCUMENT_SPECIALIST` | `claude-haiku-4-5-20251001` | `conf_get`, via `role_get document-specialist` | idem — optionnel |
| `FACTORY_REVIEW_MAX` | `2` | `conf_get` | **N**, le nombre d'allers-retours du relecteur maintenabilité (un entier ≥ 1, sinon 3) : `bin/role.sh` refuse (code 5) de le lancer une fois de plus, `bin/turn-verify.sh` refuse le push d'un tour qui l'a dépassé. Au-delà, le désaccord est un arbitrage humain (`needs-human`), pas un push « en notant » |
| `FACTORY_REFACTO_MAX` | `5` | `conf_get` | le seuil de la refacto « petite » (un entier ≥ 1, sinon 3) : `bin/role.sh` l'injecte dans le prompt de l'analyste (« Seuil : N fichiers ») et refuse (verdict `incoherent`, code 1) un `refacto: petite` dont `fichiers` en compte plus. Le seuil vit ici, jamais en dur dans le skill |
| `CLAUDE_ROLE_LAUNCH` | `-p --output-format json` | `conf_get` | `bin/role.sh` : options communes à tous les rôles sous claude, entre le binaire et ce que le script ajoute lui-même (`--model`, le mode lecture/écriture, le prompt). **C'est la porte qu'on surcharge** : posée dans le shell de l'orchestrateur plutôt que dans la conf de la boucle, elle change ce que les rôles reçoivent, et rien ne le voit. `role.sh` refuse (3) une valeur qui porte un mode de permission (`--dangerously-skip-permissions`, `--permission-mode`) — le mode est décidé par le rôle, jamais par la conf. Retirer `--output-format json` ne casse pas le lancement, ça casse la PREUVE : le rôle sort en 1. Découpée sur les blancs par `read -a`, sans guillemets : une option dont la valeur porte un espace ne passe pas par ici |
| `CODEX_ROLE_LAUNCH` | `exec --json --skip-git-repo-check` | `conf_get` | idem pour codex ; refusée (3) si elle porte `--dangerously-bypass-approvals-and-sandbox`, `-s`, `--sandbox` ou `--full-auto` — `-m`, le bac à sable et le prompt sont ajoutés par le script |
| `CLAUDE_BIN` / `CODEX_BIN` | *(vide = `claude` / `codex` du PATH)* | environnement direct | `bin/role.sh` : remplace le binaire, utilisé par les tests (`tests/fakes/claude`, `tests/fakes/codex`). **Même porte** : un `CLAUDE_BIN=/tmp/faux` posé par l'orchestrateur fabrique la preuve. La garantie tient tant que ces variables viennent de la boucle et pas du shell de l'orchestrateur (uid égal) ; la boucle rejoue `turn-verify.sh` dans son environnement avant de pousser, et la fermeture adversariale (uid distinct, signature) est reportée (docs/v2-feature.md § 4, EVOL) |
| `CODEX_HOME` | *(vide = `~/.codex`)* | environnement direct | `bin/role.sh` seulement : là où codex écrit ses rollouts (`sessions/<date>/rollout-*-<thread_id>.jsonl`), le seul endroit où le CLI inscrit le modèle — `role.sh` y cherche le rollout du thread et écrit son CHEMIN dans l'artefact (`preuve`) ; `bin/turn-verify.sh` relit ce chemin-là, il ne lit pas la variable |
| `VERBOSE` | *(vide = silencieux)* | variable Make / ligne de commande | `factory.mk` : `make loop VERBOSE=1` fait passer par `claude-stream.sh` pour suivre le tour en direct |
| `FACTORY_BIN` | `$(FACTORY_DIR)/bin` (le `bin/` du submodule lui-meme) | variable Make (`?=`) | `factory.mk` : chemin des scripts appeles par la boucle, a surcharger si l'usine est vendorisee ailleurs |
| `N` / `FOLLOW` | `200` / *(vide)* | variables Make / ligne de commande | `make factory-log` : le nombre de lignes du journal distant, ou `FOLLOW=1` pour le suivre en direct |
| `GH_FEATURE_PY` | *(vide = `bin/gh-feature.py`)* | environnement direct | `gh-release.sh`, `eva-release.sh` : remplace le lecteur de la remontée carte → feature, utilisé par les tests (un JSON illisible doit sortir en 3, pas rendre un lot vide). Même porte que `CLAUDE_BIN` : posé par un test, jamais par un agent |
| `FACTORY_TOKEN` | *(vide = un jeton est frappe via `gh-app-token.sh`)* | environnement direct | **pose par `factory.mk` a chaque tour**, un jeton pour tout le tour ; court-circuite la frappe de jeton dans `wt-cleanup.sh`, `gh-seed-labels.sh`, `gh-next-issue.sh`, `gh-feature.py`, `gh-dependencies.py`, `feature-up.sh`, `deliver.sh`, `card-state.sh` (qui se rabat ensuite sur `GH_TOKEN` : l'orchestrateur l'appelle avec son jeton réduit), `gh-comment.sh`, `gh-unblock.sh`, `gh-security-triage.py`, `gh-pr-attention.sh`, `gh-release.sh` ; utilise par les tests hors ligne (`tests/helpers.sh`) et pour travailler a la main avec un jeton deja frappe |
| `FACTORY_SSH_BIN` | *(vide = `ssh` reel)* | environnement direct | `bin/lib.sh` (`factory_ssh`) : remplace le binaire `ssh`, utilise par les tests et par un transport exotique |
| `SINCE` / `CARDS` | `2 days ago` / `6` | environnement direct | `status.sh` (`make factory-status`) : la fenêtre du journal (`journalctl --since`) et le nombre de cartes récentes affichées — des réglages d'affichage, pas de la configuration du produit |
| `EVA_GH_BIN` | *(vide = `/usr/bin/gh`)* | environnement direct | `eva-gh.sh` (le `gh` d'EVA, qui frappe son jeton depuis `EVA_GITHUB_DIR` et refuse celui de Pony) : remplace le binaire `gh`, utilisé par les tests |
| `GH_APP_ID` | *(requise)* | `conf_get` | `gh-app-token.sh` : identifiant numerique de l'App GitHub. La boucle frappe DEUX jetons par tour : le complet (ses gestes qui poussent) et un réduit, `gh-app-token.sh --agent` (`contents: read`, `issues: write`, `pull_requests: write`, `metadata: read`), seul `GH_TOKEN` de l'orchestrateur et des rôles |
| `GH_APP_INSTALL_ID` | *(requise)* | `conf_get` | `gh-app-token.sh` : identifiant d'installation de l'App sur le depot |
| `GH_APP_KEY` | `$FACTORY_STATE/secrets/gh-app.pem` | `conf_get` | `gh-app-token.sh` : chemin de la cle privee `.pem` de l'App |
| `FACTORY_RELEASE_WAIT` | `1800` | `conf_get` | `eva-release.sh --apply` : secondes au plus pendant lesquelles la CI de production est suivie après le merge, avant de rendre `deploiement: timeout` |
| `FACTORY_RELEASE_POLL` | `30` | `conf_get` | `eva-release.sh --apply` : secondes entre deux sondages de la CI de production |
| `FACTORY_EVA_STATE` | `$FACTORY_STATE/eva/watch.json` | `conf_get` | `eva-watch.sh --diff` : le fichier où vit l'état « déjà dit » (les clés vues). `--diff` n'y écrit pas : il écrit l'état PROPOSÉ dans `<fichier>.pending`, et c'est `eva-notify.sh` qui le promeut **après** un envoi Slack réussi — un envoi raté fait repartir les mêmes nouveautés. `eva-notify.sh` pose à côté son marqueur `send-absent` |
| `FACTORY_EVA_SEND` | *(vide = `eva` du PATH)* | environnement direct | `eva-notify.sh` : l'expéditeur Slack — il reçoit `send -t slack -f -` et le texte sur stdin. Le timer hôte le pose au wrapper `eva` (`nix/eva.nix`, `hermes send`) ; absent, l'usine tourne sans prévenir personne, et le dit une fois. Utilisé par les tests |
| `EVA_GITHUB_DIR` | `/run/eva` | environnement direct | `eva-gh.sh`, `eva-token.sh` : le répertoire des identifiants de l'App **d'EVA** (`github-app.env`, `github-app.pem`). Présents, ils remplacent tout `GH_APP_*` hérité. **Les scripts qui écrivent (`eva-merge.sh`, `eva-release.sh`) les exigent** : sans eux, 3 avant tout appel — jamais le jeton de Pony pour écrire, même avec `FACTORY_IN_LOOP` retiré de l'environnement. `eva-watch.sh` (lecture) se rabat sur `FACTORY_TOKEN` |
| `FACTORY_EVA_TOKEN` | *(vide)* | environnement direct | `eva-token.sh` : un jeton d'EVA déjà frappé, qui court-circuite les identifiants. **Pour les tests et la main d'un humain** ; personne ne le pose dans l'environnement de la boucle |
| `FACTORY_MERGEABLE_WAIT` | `3` | `conf_get` | `eva-merge.sh` : secondes entre deux relectures de `mergeable` quand GitHub rend `null` (trois relectures au plus) ; `0` dans les tests |
| `FACTORY_PREVIEW_PORT_BASE` | `8100` | `conf_get` | `preview.sh` (`docs/release.md`, « Les previews ») : le port d'une preview est `base + F`, F le numéro de la feature (un entier sans zéro de tête) — 8112 pour la feature 12. Le crochet du consommateur publie ce port **sur l'adresse LAN de la machine, explicitement** (docker publie par DNAT, en amont du pare-feu de l'hôte : une règle `allowedTCPPorts` n'y ferait rien) ; la plage `base` .. `base + <plus grand numéro d'issue>` est donc à savoir, pas à ouvrir. Un entier, sinon 3 |
| `FACTORY_PREVIEW_TTL` | `28800` | `conf_get` | `preview.sh reap` : secondes de vie d'une preview depuis la **dernière demande `up`** (8 h) — l'inactivité HTTP n'est pas mesurée, il n'y a pas de proxy pour la voir. Une carte UI livrée ou une demande d'EVA repousse l'échéance. Un entier, sinon 3 |
| `FACTORY_PREVIEW_HOST` | *(le nom de la machine)* | `conf_get` | `preview.sh request` (`deliver.sh`, EVA) et l'état écrit par l'hôte : l'URL affichée est `http://<hôte>:<port>`. Le défaut est `hostname`, ou `/proc/sys/kernel/hostname` quand la commande n'est pas sur le PATH (une unité Nix), sinon `localhost` — jamais une adresse 127. **À poser dans `factory.conf`** : le défaut n'est juste que sur l'hôte, et **dans un conteneur (`/.dockerenv`) sans la clé, `request` refuse en 3** plutôt que de publier l'identifiant du conteneur dans une PR. `FACTORY_PREVIEW_DANS_CONTENEUR` simule le conteneur pour les tests |
| `FACTORY_STATE/previews/` | *(sous `FACTORY_STATE`)* | chemin, pas une clé | le registre des previews, créé par `nix/preview.nix` (tmpfiles, 0770 usine) : `requests/<F>` (la boucle et EVA écrivent, l'hôte efface — seulement ce qu'il reconnaît et qui n'a pas changé sous lui), `state/<F>.json` (l'hôte seul écrit), `.tmp/` (les brouillons, renommés en place, hors du répertoire surveillé), `lock` (`flock`, dix minutes au plus). Monté dans le conteneur d'EVA sous `/previews` (écriture, un seul montage : un renommage entre deux montages n'est pas atomique) avec `/previews/state` en lecture seule par-dessus, où `preview.sh` se rabat quand `$FACTORY_STATE/previews` n'existe pas |


## Prerequis de l'outillage

Sur la machine comme sur un poste, les scripts de `bin/` et la boucle ont
besoin de `bash`, `git`, `curl`, `openssl`, `python3` (le JSON des reponses) et
`make` ; `make loop` les verifie au demarrage et refuse en 3 s'il en manque un.
Dans le conteneur, c'est l'image du devcontainer qui les fournit — l'image
`php` de Microsoft, par exemple, porte python3 ; une image nue ne le porte pas.

## Crochets

Des exécutables lus dans `tools/factory-hooks/` du dépôt consommateur, appelés
s'ils existent et ignorés sinon. C'est la surface qui remplace le fork.

| Crochet | Quand | Ce qu'il fait |
|---|---|---|
| `worktree-up <nom> <base>` | à l'admission de la première carte d'une feature (`feature-up.sh`) | fabrique l'environnement complet, quand un `git worktree` nu ne suffit pas. Reçoit `feature-<F>` et le point de départ (`origin/<branche de travail>`, ou `origin/feature/<G>` pour une pile) ; **doit laisser `.worktrees/feature-<F>` sur la branche `feature/<F>`** — `feature-up.sh` le vérifie et refuse (3) sinon |
| `worktree-down <nom>` | au nettoyage | démonte ce que `worktree-up` a monté |
| `preview-up <F> <worktree> <port>` | sur l'**hôte**, par `factory-preview.service` (`nix/preview.nix`), quand une demande `up` a été déposée et qu'aucune preview n'est montée sur la tête courante du worktree — ou que son conteneur a disparu | crée la base de la PR si elle manque, la migre, la seede, lance le serveur du worktree — **monté en lecture seule** (la preview suit l'arbre vivant et n'y écrit rien) — publié sur `<port>` **sur l'adresse LAN de la machine, explicitement** ; remplace un conteneur du même nom ; **ne rend 0 que quand l'application répond** (délai borné ; sinon ses journaux sur stderr, le conteneur retiré, 1) ; **stdout : le nom du conteneur (ligne 1), celui de la base (ligne 2, facultative)** — `preview.sh` les écrit dans l'état. Un échec : état `erreur` avec la sortie, demande effacée, 1 — jamais 3 ; l'état `erreur` est rejoué (`preview-down`) au reap suivant |
| `preview-down <F>` | sur l'hôte, sur une demande `down`, ou par `factory-preview-reap.timer` quand la preview a expiré, que son worktree n'existe plus, ou que son état est `erreur` | retire le conteneur et la base ; idempotent (rien à retirer = 0) |
| `housekeeping` | à chaque tour, après le triage de sécurité | carve les alertes propres au projet ; un échec ne tue pas le tour. **Il est invité à rattacher ses cartes à `FACTORY_SECURITY_FEATURE`** comme le triage le fait (`docs/release.md`, « Ce que le dépôt consommateur fournit ») : sans feature permanente, une alerte = une PR. La clé est dans `factory.conf` (`conf_get`), `addSubIssue` prend le node id de la feature et celui de la carte, un rattachement refusé se dit par `card-state.sh <n> needs-human` |
| `run-loop-args` | au lancement du conteneur | une ligne par argument `docker run` supplémentaire |
| `env-overrides` | à la projection du `.env` | des lignes `CLÉ=VALEUR`, lues **littéralement**, sans expansion — à une exception près : `CLÉ=$AUTRE` prend la valeur de `AUTRE` dans le `.env` du poste, et `${AUTRE}` à l'intérieur d'une valeur en fait autant (une DSN d'usine : hôte du réseau compose, identifiants du poste) ; une clé source absente est un refus. C'est ce qui permet de nommer une adresse d'infrastructure ou une DSN sans écrire ni adresse ni secret dans un fichier versionné |

## EVA

EVA (`nix/eva.nix`) tourne dans son propre conteneur, avec **sa** GitHub App
(identifiants dans `${stateDir}/secrets/eva/`, montés dans `/run/eva`). Ses
quatre scripts — `bin/eva-merge.sh`, `bin/eva-release.sh`, `bin/eva-watch.sh`,
`bin/eva-relance.sh` — se lancent depuis son clone (`/workspace/tools/factory/`,
rafraîchi sous-module compris à chaque démarrage par l'unité
`factory-eva-workspace`, avec son jeton) et frappent son jeton par
`bin/eva-token.sh`. `bin/eva-notify.sh`, lui, est appelé par le **timer hôte**
`factory-eva-notify` (toutes les deux minutes, sous l'utilisateur d'usine, avec
`FACTORY_ROOT` = l'arbre de la boucle et `EVA_GITHUB_DIR` = ses identifiants) —
pas par la boucle, qui tourne dans un conteneur sans le wrapper `eva`.

**Qui ordonne, et ce qui le garantit.** La seule serrure sur *qui* donne un
ordre à EVA est l'**allowlist Slack** de Hermes — `SLACK_ALLOWED_USERS` dans
`${stateDir}/secrets/eva/runtime.env` : seuls ces utilisateurs sont des
instructions pour EVA, tout le reste (issues, commentaires, PR, webhooks) est
de la donnée (`nix/eva-soul.md`). **C'est un geste humain, qu'aucune unité ne
provisionne** : les IDs Slack autorisés, séparés par des virgules (le format
exact est celui de Hermes — voir sa doc), dans un fichier que `tmpfiles` crée
vide. L'unité `factory-eva` **refuse de lancer la passerelle** (`ExecStartPre`)
si la clé est absente ou vide, et dit quoi poser : sans elle, n'importe qui
commanderait un merge ou une release. `--ordre "slack:<ts>"`, que les skills
passent à `eva-merge.sh` et `eva-release.sh`, est une **trace** écrite dans le
commit, **pas une vérification** : les scripts ne lisent pas Slack. C'est une
hypothèse assumée — un ordre faux ne peut venir que d'une allowlist fausse, ou
d'EVA elle-même. Ce que les scripts vérifient, eux, c'est l'**état** : la tête
que l'humain a vue (`--tete`, refus si elle a bougé), le numéro confirmé
(`--version`), le dernier mot GitHub de `FACTORY_HUMAN_LOGIN`.

**Permissions de l'App d'EVA — un geste humain, à contrôler dans les réglages
de l'App avant la première release.** `eva-merge.sh` et `eva-release.sh`
écrivent sur les branches partagées ; ce qu'ils demandent à l'API :

| Permission | Niveau | Pourquoi |
|---|---|---|
| Contents | Read and write | le merge d'une PR, le merge `staging` → `main`, le tag, la release GitHub |
| Pull requests | Read and write | lire les PR et leurs reviews, merger, commenter |
| Issues | Read and write | lire les features et leurs sous-issues, poser et retirer `factory:staged`, commenter, fermer les features |
| Checks | Read | les contrôles de la tête d'une PR (`check-runs`) — sur un dépôt privé, sans ce droit l'API rend 404 |
| Actions | Read | `eva-release.sh` suit la CI de production (`actions/runs`) jusqu'au verdict |

Une permission changée sur l'App doit être **acceptée sur l'installation**
(GitHub la met en attente) ; jusque-là l'API rend 403 et les scripts le disent,
en nommant ces lignes. Rien ici n'est vérifié par l'usine : un refus se voit au
premier ordre.

Le module pose aussi : le modèle d'EVA (`services.factory.eva.model`, défaut
`gpt-6-astra`, écrit dans la clé `model` de son `config.yaml` avant chaque
démarrage de la passerelle), son fuseau (`services.factory.eva.timezone`,
défaut `Europe/Paris` — la fenêtre de relance 8 h – 21 h est en heure locale),
ses skills (`skill/eva/*` → `~/.hermes/skills/factory/`, dont `factory-preview` :
EVA dépose une demande de preview par `preview.sh request`, et relit l'état
que l'hôte écrit — `nix/preview.nix` —, depuis `/previews/requests` en
écriture et `/previews/state` en lecture), le shim de relance
(`~/.hermes/scripts/eva-relance.sh`) et le job cron `factory-relance`
(`0 8,12,16,20 * * *`, sans agent, livré en Slack), créé une fois par l'unité
`factory-eva-setup`.
