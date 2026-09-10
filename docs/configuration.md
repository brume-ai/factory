# Configuration

Le README dit comment se servir de l'usine. Ce fichier dit ce que chaque clé fait.

> **`factory config --list` n'existe pas**, et cette ligne l'affirmait au présent.
> Aucune des deux copies de l'usine n'a jamais eu cette commande : `bin/factory`
> n'a que `status`, `doctor`, `log`, `deploy`, `stop` et `ssh`, et le reste sort
> en 2. Un doc qui ment sur ce qui existe coûte exactement une fois le temps de
> le découvrir, par personne.
>
> Ce qui existe aujourd'hui pour lire une installation, c'est **`factory
> doctor`** : il imprime le mode de livraison, le tronc, les clés qui manquent
> et, en mode `trunk`, ce que le pipeline du consommateur ne tient pas. Le
> listing des clés avec leur source reste à écrire — `conf_get` sait déjà
> résoudre, il ne manque que la source à remonter.


Toute la configuration est lue par `conf_get`/`conf_require` (`bin/lib.sh`)
ou par `factory.mk`, jamais codee en dur : c'est le point de l'extraction,
aucune valeur d'infrastructure Brume ne doit rester dans les scripts (voir
`tests/hygiene.test.sh`).

`conf_get NOM [defaut]` cherche d'abord `$NOM` dans l'environnement du
process, puis `factory.conf`, puis `.env`, a la racine du depot resolue par
`factory_root()` (`$FACTORY_ROOT`, sinon `$CLAUDE_PROJECT_DIR`, sinon
`git rev-parse --show-toplevel`, sinon le repertoire courant). `conf_require`
fait la meme chose mais sort en code 3 si la valeur manque.

> **Défaut connu, à corriger.** Le paragraphe qui suit décrit une incohérence
> réelle du code actuel : six clés ne suivent pas l'ordre de priorité annoncé.
> C'est un défaut, pas une règle — il disparaîtra, et ce paragraphe avec lui.

**Attention a une nuance reelle** : les six labels `FACTORY_*_LABEL` (sauf un
cas) sont lus en bash par `${FACTORY_XXX_LABEL:-defaut}` ou en Python par
`os.environ.get(...)`, **directement dans l'environnement du process**, pas
via `conf_get`. Les poser dans `factory.conf` ne suffit donc pas partout :
`factory.mk` ne les exporte pas non plus vers les scripts qu'il appelle (il
ne passe explicitement que `GH_REPO`). Pour qu'un label renomme vaille
partout, **exportez-le reellement** avant `make loop` (`export
FACTORY_BLOCKED_LABEL=... ; make loop`) ou posez-le dans le `.env` de
l'usine, charge par `docker run --env-file` sur la machine (donc bien dans
l'environnement du conteneur). Seul `FACTORY_HUMAN_LABEL` est lu par
`conf_get` dans `gh-pr-attention.sh` (donc `factory.conf`-compatible la) mais
par expansion directe dans `gh-next-issue.sh` (donc pas la) : exportez-le
pour couvrir les deux.

| Cle | Defaut | Lue via | Consommateur |
|---|---|---|---|
| `GH_REPO` | *(requise)* | `conf_get`/`conf_require`, transmise explicitement par `factory.mk` a chaque script qu'il appelle | `gh-next-issue.sh`, `gh-unblock.sh`, `gh-stack.sh`, `gh-seed-labels.sh`, `wt-cleanup.sh`, `gh-pr-attention.sh`, `run-loop.sh`, `deploy.sh`, `bin/factory stop`, garde de `factory.mk` |
| `FACTORY_DELIVERY` | `pull-request` | `conf_get` (`delivery_mode`/`delivery_require` dans `bin/lib.sh`) ; `factory.mk` **delegue a ce meme lecteur** au lieu d'en avoir un second | le mode de livraison : `pull-request` (la boucle rend une PR, le merge humain ferme la carte) ou `trunk` (elle pousse sur le tronc de recette, le pipeline du consommateur ferme la carte). Toute autre valeur : **code 3**, jamais de repli silencieux. Voir `docs/livraison.md` |
| `FACTORY_TRUNK` | `main` | `conf_get` | garde de branche et rebase du tronc dans `factory.mk` (`make loop`), `gh-stack.sh` (base par defaut), `deploy.sh` |
| `FACTORY_GIT_NAME` | *(requise)* | variable Make (`-include factory.conf`), verifiee au demarrage de `make loop` | `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME` exportes par `factory.mk` avant chaque tour |
| `FACTORY_GIT_EMAIL` | *(requise)* | idem | `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` idem |
| `FACTORY_HUMAN_LOGIN` | *(requise)* | `conf_get`/`conf_require` | `gh-pr-attention.sh` (qui traite une review comme une instruction) et le canal de confiance du skill `github-loop` |
| `FACTORY_BOT_LOGIN` | *(requise)* | `conf_require`/`conf_get` | `gh-pr-attention.sh` : le login sous lequel l'usine PARLE. C'est sa réponse qui marque un retour du relecteur comme traité — sans défaut possible, une valeur fausse rendrait chaque PR soit muette, soit éternellement réveillée |
| `FACTORY_HUMAN_LABEL` | `factory:needs-human` | `conf_get` dans `gh-pr-attention.sh` ; environnement direct dans `gh-next-issue.sh` | label « decision humaine requise, hors file » |
| `FACTORY_BLOCKED_LABEL` | `factory:blocked` | environnement direct | `gh-next-issue.sh` (exclu de la file), `gh-unblock.sh` (retire quand le bloqueur tombe) |
| `FACTORY_EPIC_LABEL` | `factory:epic` | environnement direct | `gh-next-issue.sh` (exclu de la file : chapeau d'epopee, pas du travail) |
| `FACTORY_BUSY_LABEL` | `factory:in-progress` | environnement direct | `gh-next-issue.sh` (carte deja prise), `gh-security-triage.py` (`FROZEN`, spec gelee) |
| `FACTORY_DONE_LABEL` | `factory:delivered` | environnement direct | `gh-next-issue.sh` (carte livree), `gh-security-triage.py` (`FROZEN`) |
| `FACTORY_PRIORITY_LABEL` | `factory:priority` | environnement direct | `gh-next-issue.sh` (fait passer devant la file), pose par `gh-security-triage.py` sur les cartes qu'il cree |
| `FACTORY_STATE` | `/srv/factory` | `conf_get` | racine du volume persistant de l'usine : `push-env.sh`, `run-loop.sh`, `status.sh`, `deploy.sh`, `bin/factory stop`, fallback du chemin de `GH_APP_KEY` |
| `FACTORY_REPO_DIR` | `$FACTORY_STATE/workspace/<basename de GH_REPO>` | `conf_get` | `run-loop.sh`, `deploy.sh`, `bin/factory stop` : chemin du depot sur la machine |
| `FACTORY_IMAGE_TAG` | `factory:dev` | `conf_get` | `run-loop.sh` : tag de l'image devcontainer lancee par `docker run` |
| `FACTORY_HOST` | *(requise avec `FACTORY_KEY`)* | `conf_get`/`conf_require` | `bin/lib.sh` (`factory_ssh`), `status.sh`, `deploy.sh`, `bin/factory log`/`ssh` |
| `FACTORY_KEY` | *(requise avec `FACTORY_HOST`)* | `conf_get`/`conf_require` | idem : chemin de la cle privee SSH vers l'usine |
| `FACTORY_SSH_OPTS` | *(vide)* | `conf_get`, expansion non quotee dans la commande `ssh` | `bin/lib.sh` (`factory_ssh`), `bin/factory log`/`ssh` : options `ssh` supplementaires (ex. `-o ProxyJump=...`) |
| `FACTORY_NAME` | `usine` | `conf_get` | `status.sh`, `deploy.sh` : nom affiche dans les messages |
| `FACTORY_ENV_DENY` | *(vide)* | `conf_get` | `push-env.sh` : liste blanc-separee de variables du `.env` racine qui NE traversent PAS vers l'usine (en plus du motif universel `^(PROD_|.*_SUDO_)`) |
| `FACTORY_ENV_DENY_PATTERN` | *(vide)* | `conf_get` | `push-env.sh` : motif regex etendu supplementaire, propre au consommateur |
| `FACTORY_ENV_PATH` | `$FACTORY_STATE/secrets/env` | environnement direct (`${FACTORY_ENV_PATH:-...}`) | `push-env.sh` : chemin distant ou le `.env` compose est depose |
| `LOOP_SLEEP` | `60` | variable Make (`?=`, surchargeable sur la ligne de commande `make loop LOOP_SLEEP=30`) | `factory.mk` : attente entre deux sondages quand la file est vide |
| `LOOP_MAX_RETRY` | `3` | variable Make | `factory.mk` : garde anti-tourniquet, la boucle s'arrete si la meme carte revient plus de N fois sans avancer |
| `CLAUDE_LAUNCH` | `claude --dangerously-skip-permissions --model claude-opus-5 --effort low` | variable Make | `factory.mk` : commande qui lance l'agent Claude a chaque tour (`MAIN=claude`) |
| `CODEX_LAUNCH` | `codex exec --dangerously-bypass-approvals-and-sandbox` | variable Make | `factory.mk` : commande qui lance Codex (`MAIN=codex`) |
| `MAIN` | `claude` | variable Make | `factory.mk` : `claude` ou `codex`, choisit l'agent principal de la boucle |
| `VERBOSE` | *(vide = silencieux)* | variable Make / ligne de commande | `factory.mk` : `make loop VERBOSE=1` fait passer par `claude-stream.sh` pour suivre le tour en direct |
| `FACTORY_BIN` | `$(FACTORY_DIR)/bin` (le `bin/` du submodule lui-meme) | variable Make (`?=`) | `factory.mk` : chemin des scripts appeles par la boucle, a surcharger si l'usine est vendorisee ailleurs |
| `FACTORY_TOKEN` | *(vide = un jeton est frappe via `gh-app-token.sh`)* | environnement direct | court-circuite la frappe de jeton dans `wt-cleanup.sh`, `gh-seed-labels.sh`, `gh-next-issue.sh`, `gh-unblock.sh`, `gh-security-triage.py`, `gh-stack.sh`, `gh-pr-attention.sh` ; utilise par les tests hors ligne (`tests/helpers.sh`) et pour travailler a la main avec un jeton deja frappe |
| `FACTORY_SSH_BIN` | *(vide = `ssh` reel)* | environnement direct | `bin/lib.sh` (`factory_ssh`) : remplace le binaire `ssh`, utilise par les tests et par un transport exotique |
| `GH_APP_ID` | *(requise)* | `conf_get` | `gh-app-token.sh` : identifiant numerique de l'App GitHub |
| `GH_APP_INSTALL_ID` | *(requise)* | `conf_get` | `gh-app-token.sh` : identifiant d'installation de l'App sur le depot |
| `GH_APP_KEY` | `$FACTORY_STATE/secrets/gh-app.pem` | `conf_get` | `gh-app-token.sh` : chemin de la cle privee `.pem` de l'App |
| `FACTORY_DEPLOY_JOB` | *(requise en `FACTORY_DELIVERY = trunk`)* | `conf_get` | `doctor.sh` : `<chemin du workflow>:<identifiant du job>` — le job de CI qui déclenche le déploiement. Le déclarer, c'est déclarer que ce n'est PAS l'hébergeur qui déploie au push. Le docteur prouve ensuite que le fichier existe, que le job existe, qu'il est en aval d'une suite (`needs:`, ou un déclencheur `workflow_run` conditionné à `conclusion == 'success'`) et qu'il ne s'en échappe pas par un `always()` **de niveau job**. Ignorée en `pull-request` |
| `FACTORY_CLOSE_WORKFLOW` | *(requise en `FACTORY_DELIVERY = trunk`)* | `conf_get` | `doctor.sh` : le chemin du workflow qui ferme les cartes sur déploiement réussi. **Son déclencheur vous appartient** — l'usine ne sait pas ce qu'est votre preprod, et reconnaître le mécanisme d'un consommateur connu remonterait sa politique ici, ce que `docs/livraison.md` interdit. Le docteur prouve seulement que le fichier existe, qu'il ferme vraiment une carte (`gh issue close`, `issues.update`, ou un état passé à `closed`), qu'un filtre `head_branch` éventuel nomme bien `FACTORY_TRUNK`, et qu'il a `issues: write` s'il déclare un bloc `permissions:` et ferme avec le jeton par défaut. Ignorée en `pull-request` |
| `FACTORY_PROD_TRUNK` | *(requise en `FACTORY_DELIVERY = trunk`)* | `conf_get` | `doctor.sh` : la branche dont le déploiement est la **production**, forcément différente de `FACTORY_TRUNK`. C'est la seule façon pour une machine de distinguer une usine posée sur une branche de recette d'une usine posée sur la production — l'écart d'un caractère que `docs/livraison.md` désigne comme le plus dangereux. Le docteur prouve que les deux noms diffèrent (casse comprise) et que la branche existe ; que ce soit bien elle qui déploie la production reste **déclaré**. Ignorée en `pull-request` |


### Les trois clés du mode `trunk` : nommer, plutôt que cocher

Elles ne sont pas une conséquence de plus de `FACTORY_DELIVERY` — elles ne
changent le comportement d'aucun script gouverné. Elles sont l'**entrée** de
`factory doctor` : ce que le consommateur doit dire pour que la machine puisse
prouver le reste.

Elles ont cette forme parce que l'usine ne sait reconnaître ni « déployer », ni
« fermer une carte chez cet hébergeur-là », ni « la branche de production » :
aucune de ces trois choses n'a de signature commune à deux consommateurs. La
tentation serait alors un booléen — *« oui, mon pipeline est gréé »*. Il ne vaut
rien : une case se coche sans lire, et une fois cochée elle survit à la refonte
qui l'a rendue fausse. **Un chemin, lui, pourrit visiblement** — le fichier
disparaît, le job est renommé, la branche est supprimée — et le docteur le voit.

Le partage est donc : le consommateur déclare **où**, la machine prouve **quoi**.
Ce qui reste indécidable — le réglage « push-to-deploy » de l'hébergeur, qu'un
job nommé `deploy` déploie vraiment, que le tronc de production déploie vraiment
la production — `factory doctor` l'imprime en clair à la fin plutôt que de le
deviner.

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
