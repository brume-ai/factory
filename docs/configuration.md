# Configuration

Le README dit comment se servir de l'usine. Ce fichier dit ce que chaque clé fait.

`factory config --list` rend les mêmes valeurs, résolues, avec leur source.


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
appelant résout les rôles par `label_get` et lui passe les quatre qu'il lit
(`PRIO`, `BUSY`, `DONE`, `STAGED`), ce que `factory.mk` fait, et le Python les
lit **strictement** — aucun défaut à lui, sortie en 3 si l'un manque. Un défaut
écrit côté Python serait un second domicile pour le nom, invisible depuis
`factory.conf` : le renommage marcherait dans les scripts shell et pas là, et le
triage poserait sa priorité sous l'ANCIEN nom — une carte de sécurité hors de la
file, sans que rien ne le dise.

**Deux branches nommées, et elles ne disent pas la même chose.** `FACTORY_TRUNK`
est la branche de **production** — l'usine n'y écrit jamais — et `FACTORY_STAGING`
la branche de **travail**, la seule où elle a le droit d'écrire. Les scripts qui
nomment une branche appellent `branches_require` (`bin/lib.sh`), qui les résout,
rogne leurs blancs, réapplique les défauts et **refuse de démarrer en code 3 si
les deux sont la même**. Le pourquoi est dans [`docs/release.md`](release.md).

| Cle | Defaut | Lue via | Consommateur |
|---|---|---|---|
| `GH_REPO` | *(requise)* | `conf_get`/`conf_require` ; `factory.mk` la lit par `conf_get` et l'exporte pour le tour | `gh-next-issue.sh`, `gh-unblock.sh`, `gh-stack.sh`, `gh-seed-labels.sh`, `gh-stage-pr.sh`, `gh-release.sh`, `wt-cleanup.sh`, `gh-pr-attention.sh`, `run-loop.sh`, `deploy.sh`, `bin/factory stop`, garde de `factory.mk` |
| `FACTORY_TRUNK` | `main` | `conf_get`, via `branches_require` | la branche de **PRODUCTION**, cible de la release. **L'usine n'y écrit jamais.** Lue par `bin/lib.sh` (la garde) et `bin/gh-release.sh` (le tag à partir duquel les cartes sont fermées) — et par personne d'autre : aucun script d'écriture ne la nomme. Son NOM, en revanche, **est** dans l'environnement de l'agent : `branches_require` exporte la paire normalisée, et `factory.mk` l'appelle dans le shell même qui lance l'agent (le pourquoi de cet export est écrit dans `bin/lib.sh`). Ce n'est pas un trou : ce qui protège la production, c'est la protection de branche, jamais l'ignorance de son nom |
| `FACTORY_STAGING` | `staging` | `conf_get`, via `branches_require` | la branche de **TRAVAIL**, la seule où l'usine écrit : base par défaut de `gh-stack.sh`, cible du merge de `gh-stage-pr.sh`, garde de branche et `fetch`/`merge --ff-only` de `factory.mk`, `checkout --force -B` de `deploy.sh`, point de comparaison de `wt-resume.sh`, branche que suit l'environnement en ligne. Jamais lue par une variable Make |
| `FACTORY_MILESTONE` | *(vide = aucun filtre)* | `conf_get` | `gh-next-issue.sh`, et personne d'autre : **le jalon nomme la release et le sondage le fait respecter**. Filtrage côté client sur le champ `milestone` déjà présent dans la réponse — aucun appel de plus. Vide signifie *aucun filtre*, pas « jalon sans nom » |
| `FACTORY_GIT_NAME` | *(requise)* | `conf_get`/`conf_require`, au demarrage de `make loop` | `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME` exportes par `factory.mk` avant chaque tour |
| `FACTORY_GIT_EMAIL` | *(requise)* | idem | `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` idem |
| `FACTORY_HUMAN_LOGIN` | *(requise)* | `conf_get`/`conf_require` | `gh-pr-attention.sh` (qui traite sa parole comme une instruction : il réveille une PR ouverte, il CARVE sur une PR déjà intégrée) et le canal de confiance du skill `github-loop` |
| `FACTORY_BOT_LOGIN` | *(requise)* | `conf_require`/`conf_get` | `gh-pr-attention.sh` : le login sous lequel l'usine PARLE. C'est sa réponse qui marque un retour du relecteur comme traité — sans défaut possible, une valeur fausse rendrait chaque PR soit muette, soit éternellement réveillée |
| `FACTORY_BUSY_LABEL` | `factory:in-progress` | `conf_get`, via `label_get busy` | `gh-next-issue.sh` (carte deja prise), `gh-security-triage.py` (`FROZEN`, spec gelee) |
| `FACTORY_BLOCKED_LABEL` | `factory:blocked` | `conf_get`, via `label_get blocked` | `gh-next-issue.sh` (exclu de la file), `gh-unblock.sh` (retire quand le bloqueur tombe) |
| `FACTORY_HUMAN_LABEL` | `factory:needs-human` | `conf_get`, via `label_get human` | label « decision humaine requise, hors file » : `gh-next-issue.sh`, `gh-pr-attention.sh` |
| `FACTORY_EPIC_LABEL` | `factory:epic` | `conf_get`, via `label_get epic` | `gh-next-issue.sh` (exclu de la file : chapeau d'epopee, pas du travail) |
| `FACTORY_DONE_LABEL` | `factory:delivered` | `conf_get`, via `label_get done` | `gh-next-issue.sh` (carte livree, PR ouverte), `gh-security-triage.py` (`FROZEN`) |
| `FACTORY_STAGED_LABEL` | `factory:staged` | `conf_get`, via `label_get staged` | **intégrée à la branche de travail, attend la release** — posé par `gh-stage-pr.sh` au merge, retiré par `gh-release.sh` à la fermeture, mis de côté par `gh-next-issue.sh`. **La file de relecture humaine, c'est ce label dans le jalon en cours** |
| `FACTORY_PRIORITY_LABEL` | `factory:priority` | `conf_get`, via `label_get priority` | `gh-next-issue.sh` (fait passer devant la file), pose par `gh-security-triage.py` et par `gh-pr-attention.sh` sur les cartes qu'ils creent |
| `FACTORY_IN_LOOP` | *(vide ; posée à `1` par `factory.mk` seulement)* | environnement direct | **Ce n'est pas une clé de configuration, et personne ne la pose à la main** : c'est le marqueur que la boucle exporte et que `gh-release.sh` lit pour sortir en 3. Il rend exécutable « la release est un geste humain » — sans lui, un agent qui hérite de `GH_TOKEN` fermerait des cartes que personne n'a relues |
| `FACTORY_STATE` | `/srv/factory` | `conf_get` | racine du volume persistant de l'usine : `push-env.sh`, `run-loop.sh`, `status.sh`, `deploy.sh`, `bin/factory stop`, fallback du chemin de `GH_APP_KEY` |
| `FACTORY_REPO_DIR` | `$FACTORY_STATE/workspace/<basename de GH_REPO>` | `conf_get` | `run-loop.sh`, `deploy.sh`, `bin/factory stop` : chemin du depot sur la machine |
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
| `LOOP_SLEEP` | `60` | variable Make (`?=`, surchargeable sur la ligne de commande `make loop LOOP_SLEEP=30`) | `factory.mk` : attente entre deux sondages quand la file est vide |
| `LOOP_MAX_RETRY` | `3` | variable Make | `factory.mk` : garde anti-tourniquet, la boucle s'arrete si la meme carte revient plus de N fois sans avancer |
| `CLAUDE_LAUNCH` | `claude --dangerously-skip-permissions --model claude-opus-5 --effort low` | variable Make | `factory.mk` : commande qui lance l'agent Claude a chaque tour (`MAIN=claude`) |
| `CODEX_LAUNCH` | `codex exec --dangerously-bypass-approvals-and-sandbox` | variable Make | `factory.mk` : commande qui lance Codex (`MAIN=codex`) |
| `MAIN` | `claude` | variable Make | `factory.mk` : `claude` ou `codex`, choisit l'agent principal de la boucle |
| `VERBOSE` | *(vide = silencieux)* | variable Make / ligne de commande | `factory.mk` : `make loop VERBOSE=1` fait passer par `claude-stream.sh` pour suivre le tour en direct |
| `FACTORY_BIN` | `$(FACTORY_DIR)/bin` (le `bin/` du submodule lui-meme) | variable Make (`?=`) | `factory.mk` : chemin des scripts appeles par la boucle, a surcharger si l'usine est vendorisee ailleurs |
| `FACTORY_TOKEN` | *(vide = un jeton est frappe via `gh-app-token.sh`)* | environnement direct | **pose par `factory.mk` a chaque tour**, un jeton pour tout le tour ; court-circuite la frappe de jeton dans `wt-cleanup.sh`, `gh-seed-labels.sh`, `gh-next-issue.sh`, `gh-unblock.sh`, `gh-security-triage.py`, `gh-stack.sh`, `gh-pr-attention.sh`, `gh-stage-pr.sh`, `gh-release.sh` ; utilise par les tests hors ligne (`tests/helpers.sh`) et pour travailler a la main avec un jeton deja frappe |
| `FACTORY_SSH_BIN` | *(vide = `ssh` reel)* | environnement direct | `bin/lib.sh` (`factory_ssh`) : remplace le binaire `ssh`, utilise par les tests et par un transport exotique |
| `GH_APP_ID` | *(requise)* | `conf_get` | `gh-app-token.sh` : identifiant numerique de l'App GitHub |
| `GH_APP_INSTALL_ID` | *(requise)* | `conf_get` | `gh-app-token.sh` : identifiant d'installation de l'App sur le depot |
| `GH_APP_KEY` | `$FACTORY_STATE/secrets/gh-app.pem` | `conf_get` | `gh-app-token.sh` : chemin de la cle privee `.pem` de l'App |


## Crochets

Des exécutables lus dans `tools/factory-hooks/` du dépôt consommateur, appelés
s'ils existent et ignorés sinon. C'est la surface qui remplace le fork.

| Crochet | Quand | Ce qu'il fait |
|---|---|---|
| `worktree-up <nom> <base>` | à la prise d'une carte | fabrique l'environnement complet, quand un `git worktree` nu ne suffit pas |
| `worktree-down <nom>` | au nettoyage | démonte ce que `worktree-up` a monté |
| `housekeeping` | à chaque tour, après le triage de sécurité | carve les alertes propres au projet ; un échec ne tue pas le tour |
| `run-loop-args` | au lancement du conteneur | une ligne par argument `docker run` supplémentaire |
| `env-overrides` | à la projection du `.env` | des lignes `CLÉ=VALEUR`, lues **littéralement**, sans expansion |
