# factory

Usine de developpement pilotee par les issues GitHub : une boucle ralph prend
les cartes une par une et mene chacune jusqu'a une pull request prete a
relire, avec un agent NEUF par carte. Pas de colonnes, pas de tableau a
entretenir a la main : l'etat d'une carte est porte par ses labels
`factory:*`, et la file est **opt-out** : une issue ouverte EST du travail,
ce qui se declare c'est l'exception (prise, livree, bloquee, en attente d'un
humain).

Extrait de [Brume](https://github.com/Brume-ai) au SHA `12ac9e92c00fe8ce71472ff3a06f2818d690f05e`,
ou cet outillage est ne et a paye ses lecons : les commentaires dates des
scripts sont ces lecons, ils voyagent avec le code. Generalise ici pour etre
consomme par n'importe quel depot via un submodule git, sans rien qui
appartienne a l'infrastructure d'origine.

Ce que le depot fournit :

- `bin/` : les scripts d'exploitation (sondage de la file, jeton d'App
  GitHub, gestion des worktrees, piles de PR, statut et deploiement de la
  machine).
- `factory.mk` : la boucle elle-meme, a inclure dans le `Makefile` du
  consommateur (`make loop`).
- `skill/github-loop/` : le skill Claude qui decrit un TOUR de la boucle
  (comment prendre une carte, la mener a une PR, s'arreter).
- `nix/` : un module NixOS pour la machine qui heberge la boucle, plus un
  gabarit d'hote.
- `tests/` : un harnais de test hors ligne (aucun reseau, aucune dependance
  externe) qui couvre les scripts et le skill.

Ce que ce depot n'est PAS : une application. Rien ici ne tourne seul, tout
est concu pour etre inclus dans un depot consommateur qui, lui, porte le
produit.

## Consommer l'usine

```
git submodule add https://github.com/Brume-ai/factory tools/factory
printf 'include tools/factory/factory.mk\n' >> Makefile
cat > factory.conf <<'EOF'
GH_REPO = mon-org/mon-depot
FACTORY_GIT_NAME = mon-usine[bot]
FACTORY_GIT_EMAIL = 123456+mon-usine[bot]@users.noreply.github.com
FACTORY_HUMAN_LOGIN = mon-login
EOF
# Secrets (gitignores) : GH_APP_ID, GH_APP_INSTALL_ID, GH_APP_KEY (chemin du
# .pem de votre App GitHub). AVANT gh-seed-labels.sh : il frappe un jeton
# d'App pour poser les labels, et sans ces trois cles la frappe echoue.
cat > .env <<'EOF'
GH_APP_ID=123456
GH_APP_INSTALL_ID=987654
GH_APP_KEY=/chemin/vers/votre-app.pem
EOF
mkdir -p .claude/skills
ln -s ../../tools/factory/skill/github-loop .claude/skills/github-loop
bash tools/factory/bin/gh-seed-labels.sh
echo "make verify est le contrat." > VERIFY.md
make loop
```

`factory.conf` est **versionne** (pas de secret dedans) : c'est la
configuration du produit, la meme pour toute l'equipe. `.env` est
**gitignore** : c'est la ou vivent les secrets, en local comme sur la
machine d'usine. Les deux sont lus par les memes scripts, dans cet ordre de
priorite : **variable d'environnement du process** d'abord, puis
`factory.conf`, puis `.env` (voir la reference de configuration ci-dessous
pour les cles qui echappent a cette regle).

## Reference de configuration

Toute la configuration est lue par `conf_get`/`conf_require` (`bin/lib.sh`)
ou par `factory.mk`, jamais codee en dur : c'est le point de l'extraction,
aucune valeur d'infrastructure Brume ne doit rester dans les scripts (voir
`tests/hygiene.test.sh`).

`conf_get NOM [defaut]` cherche d'abord `$NOM` dans l'environnement du
process, puis `factory.conf`, puis `.env`, a la racine du depot resolue par
`factory_root()` (`$FACTORY_ROOT`, sinon `$CLAUDE_PROJECT_DIR`, sinon
`git rev-parse --show-toplevel`, sinon le repertoire courant). `conf_require`
fait la meme chose mais sort en code 3 si la valeur manque.

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
| `FACTORY_TRUNK` | `main` | `conf_get` | garde de branche et rebase du tronc dans `factory.mk` (`make loop`), `gh-stack.sh` (base par defaut), `deploy.sh` |
| `FACTORY_GIT_NAME` | *(requise)* | variable Make (`-include factory.conf`), verifiee au demarrage de `make loop` | `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME` exportes par `factory.mk` avant chaque tour |
| `FACTORY_GIT_EMAIL` | *(requise)* | idem | `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` idem |
| `FACTORY_HUMAN_LOGIN` | *(requise)* | `conf_get`/`conf_require` | `gh-pr-attention.sh` (qui traite une review comme une instruction) et le canal de confiance du skill `github-loop` |
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

## Hooks

Le depot consommateur peut deposer des hooks executables dans
`tools/factory-hooks/`. Absents, le comportement retombe sur un geste nu
(worktree git simple, aucun argument supplementaire, pas de surcharge de
`.env`) : les hooks ne sont jamais requis, ils existent pour les cas ou le
geste nu ne suffit pas (une carte a besoin d'une base applicative, d'une
pile de preview, d'une route).

- **`worktree-up <nom> <base>`** : appele par le skill `github-loop`
  (`<Tend_A_Pull_Request>`/etape 5) quand il existe et qu'il est executable.
  `<nom>` est `card-<n>` (le nom du worktree, sans le chemin), `<base>` est
  la reference a cloner (`origin/<base_calculee>`, par ex.
  `origin/main`). Le hook doit fabriquer un ENVIRONNEMENT complet, pas
  seulement un `git worktree add` : base, pile applicative, route si le
  produit en a besoin, et peut refuser de creer un environnement de plus si
  le projet plafonne le parallelisme (l'agent doit alors s'arreter proprement,
  jamais contourner le hook). Sans lui, le skill fait un simple
  `git worktree add -b "card/$N" ".worktrees/card-$N" "origin/$base"`.

- **`worktree-down <nom>`** : appele par `bin/wt-cleanup.sh` quand la PR
  d'une carte est mergee ou fermee, et par le skill en fin de tour. `<nom>`
  est le meme `card-<n>` que pour `worktree-up`. Doit detruire tout ce que
  `worktree-up` avait cree (environnement complet, pas seulement le
  worktree git). Sans lui, `wt-cleanup.sh` fait un
  `git worktree remove --force` nu et supprime la branche `card/<n>`.

- **`run-loop-args`** : appele par `bin/run-loop.sh` (sans argument), qui lit
  sa **sortie standard, une ligne par argument**, et les ajoute a la commande
  `docker run` qui lance `make loop` dans l'image du devcontainer. Sert a
  passer les options propres au projet (socket docker partage, reseau
  compose, alias reseau vers d'autres services) sans que `run-loop.sh` les
  connaisse. Absent, aucun argument supplementaire n'est ajoute.

- **`env-overrides`** : pas un executable mais un fichier texte, lu par
  `bin/push-env.sh`. Lignes `KEY=VALUE` (les lignes vides et les commentaires
  `#...` sont ignores) : chaque cle y ecrase, dans le `.env` compose pour
  l'usine, la valeur portee par le `.env` du poste. Sert aux valeurs qui sont
  JUSTES sur un poste de developpement et FAUSSES sur la machine d'usine
  (DSN de base de donnees, domaines d'adressage internes...). Absent, aucune
  surcharge n'est appliquee (a part `GH_APP_KEY`, toujours force par
  `push-env.sh` vers le chemin sur le volume persistant).

## VERIFY.md

Le skill `github-loop` (etape 4, `<Tend_A_Pull_Request>`) delegue au
consommateur la definition de ce que « verifier » veut dire : il lit
**`VERIFY.md` a la racine du depot consommateur** et execute ce qu'il
demande, avant de livrer une pull request. **Sans `VERIFY.md`, le contrat par
defaut est `make verify`.**

Ce fichier n'a pas de format impose : c'est une procedure lisible par un
agent, executable, qui dit exactement quoi lancer pour prouver qu'une carte
est terminee (tests, lint, une capture d'ecran d'un parcours precis...).
`VERIFY.md` appartient au consommateur : ce depot n'en fournit pas de
gabarit au-dela de l'exemple minimal du quickstart
(`echo "make verify est le contrat." > VERIFY.md`), parce que la bonne
procedure depend entierement du produit qu'il porte.

Le seuil compte, pas la forme du diff : une verification non jouee, ou jouee
mais jugee non conforme, empeche la PR d'etre prete : ce n'est pas un motif
de blocage, c'est le prerequis de l'etape 5.

## La machine d'usine (NixOS)

`nix/` fournit un module NixOS (`nixosModules.factory`, dans `nix/module.nix`)
qui installe et fait tourner la boucle sur une machine dediee, plus un
gabarit d'hote (`nix/host-template/`) qui sert a la fois de verification
d'evaluation en CI et de point de depart pour un VPS reel.

**Mise en place** :

1. Dans le depot consommateur, importer le module depuis ce flake
   (`inputs.factory.url = "github:Brume-ai/factory?dir=nix"` ou equivalent
   selon votre gestion des inputs), et importer `nixosModules.factory` dans
   la configuration NixOS de la machine.
2. Copier `nix/host-template/` comme point de depart, remplir `repoUrl` (URL
   HTTPS du depot consommateur) et le socle disque reel (le gabarit fourni
   n'est qu'evaluable, pas deployable tel quel : partitionnement a
   remplacer, `disko` ou `fileSystems` explicites).
3. Deployer par `nixos-anywhere` sur le VPS cible.
4. Deposer les **prerequis humains** sur `${stateDir}/secrets` (defaut
   `/srv/factory/secrets`) : rien de tout cela n'est automatise, c'est un
   geste volontairement manuel a chaque provisionnement.
   - `gh-app.pem` : la cle privee de l'App GitHub.
   - `env` : le `.env` de l'usine, compose et depose par `bin/push-env.sh`
     depuis un poste (jamais ecrit a la main sur la machine).
   - `authorized_keys` : les cles publiques SSH autorisees (lu par `sshd`
     via `authorizedKeysFiles`, pas par `keyFiles`, parce qu'un flake
     s'evalue en mode pur et refuse tout chemin hors de son arbre).
   - `claude-home` et `.claude.json` : le home persistant de Claude, et son
     fichier d'approbation de workspace (`claude-home/.claude.json`), montes
     a part parce que Claude le lit hors de `~/.claude`.
   - `codex-home`, `gemini-home` : les homes persistants des autres agents,
     memes raisons (survivre a une reconstruction de conteneur).

**Ce que le module fait tourner** : trois services systemd en chaine
(`factory-repo` clone/met a jour le depot par jeton d'App frappe inline,
`factory-image` construit l'image devcontainer via la CLI Dev Containers,
jamais `docker build` directement (une Feature n'est appliquee que par cet
outillage), `factory-loop` lance `run-loop.sh` en continu, `Restart = always`).
Docker range ses couches sur le volume persistant par montage lie
(`/var/lib/docker` et `/var/lib/containerd`), pas par `data-root` : docker 29
range les images dans le magasin de containerd, que `data-root` ne
gouverne pas.

**Piloter la machine depuis un poste** :

- `make factory-status` (ou `factory` seul, une fois `bin/factory` sur le
  `PATH`) : etat de l'usine (boucle active ou non, carte en cours, cartes
  recentes, sante : session agent, disque, incidents).
- `make factory-log` (`FOLLOW=1` pour suivre en direct, `N=<lignes>` sinon,
  200 par defaut) : le journal systemd de la boucle.
- `make factory-deploy` : met le depot de l'usine au niveau de
  `origin/$(FACTORY_TRUNK)` (jeton frappe au vol, `reset --hard`, redemarrage
  de la boucle uniquement si elle dort, jamais au milieu d'une carte).

## Bump chez un consommateur

L'usine est versionnee au moins une fois, parfois deux, chez un consommateur
qui la deploie sur NixOS. **Les deux epinglages doivent bouger ENSEMBLE** :
un submodule mis a jour sans le flake nix (ou l'inverse) fait tourner la
machine avec un outillage different de celui que le poste croit avoir.

1. Le submodule git : `git -C tools/factory pull origin main`, puis
   `git add tools/factory && git commit` dans le depot consommateur : le
   commit porte le nouveau pointeur de submodule.
2. Si la machine d'usine est deployee en NixOS et importe ce depot comme
   input flake : `nix flake update factory` (ou le nom donne a l'input dans
   le `flake.nix` du consommateur) pour faire bouger `flake.lock`, puis
   commit du lock avec le meme geste de deploiement.

`make factory-deploy` applique ensuite le nouveau code cote depot (le
`git reset --hard` sur `origin/$(FACTORY_TRUNK)`) ; un changement du module
Nix lui-meme (`nix/module.nix`) demande un redeploiement NixOS de la machine
(`nixos-rebuild` via votre pipeline habituel, hors du perimetre de ce
`Makefile`).

## Tests et contribution

`bash tests/run.sh` lance tous les `tests/*.test.sh` (16 fichiers au moment
d'ecrire ceci, hygiene comprise) : zero dependance externe, zero reseau.
`tests/fakes/curl` remplace `curl` sur le `PATH` des tests
(`tests/helpers.sh` le fait via `PATH="$REPO/tests/fakes:$PATH"`) : il ne
frappe jamais l'API GitHub, il lit et journalise depuis `$FAKE_HTTP_DIR`.

**Contrat des fixtures HTTP hors ligne.** Un appel `curl` vers
`https://api.github.com/<chemin>` est reecrit en un nom de fichier de
fixture par la meme transformation que `tr '/?&=%:' '______'` applique a
`<chemin>` (le prefixe `https://api.github.com/` retire) : chaque caractere
de separation d'URL (`/ ? & = % :`) devient un `_`. Une fixture pour
`repos/mon-org/mon-depot/issues?state=open&per_page=100` s'appelle donc
`repos_mon-org_mon-depot_issues_state=open_per_page=100.json`... en
pratique, ecrivez le fichier attendu dans `$FAKE_HTTP_DIR/<slug>.json` (corps
de la reponse, code 200 implicite) et optionnellement
`$FAKE_HTTP_DIR/<slug>.code` (code HTTP explicite, prioritaire sur le
defaut). Sans fixture, le faux `curl` rend `404` avec un corps `{}`. Chaque
appel est aussi journalise dans `$FAKE_HTTP_DIR/calls.log`
(`<methode> <chemin> <donnees>`), ce qui permet aux tests d'asserter QUELS
appels ont ete faits, pas seulement leur resultat.

**`SHELL := bash` dans `factory.mk`** s'applique a TOUT le Makefile
consommateur qui l'inclut, pas seulement a la recette `loop` : `include`
importe des variables et regles dans un seul et meme Makefile, `SHELL` n'est
donc pas scope au fichier qui la definit. Si le Makefile consommateur a besoin
d'un `/bin/sh` different pour ses propres recettes, definissez `SHELL` a
nouveau APRES le `include`.

**`.SHELLFLAGS` dans `factory.mk`.** Un commentaire de la recette `loop`
mentionne que `.SHELLFLAGS` porte `-e` (« `.SHELLFLAGS` porte `-e`, donc une
affectation dont la substitution echoue fait sortir le shell AVANT le test
du code retour »). C'est un heritage du Makefile Brume d'origine :
`factory.mk` **ne definit `.SHELLFLAGS` nulle part lui-meme**. La recette
reste correcte que le Makefile qui l'inclut positionne `-e` ou non : c'est
justement pour ca que `|| rc=$$?` est pose explicitement partout ou un code
de sortie non nul est un cas normal (file vide, raté passager) ; la recette
ne compte pas sur `-e` pour se comporter correctement, elle fonctionne a
l'identique avec ou sans.

Avant toute contribution : `bash tests/run.sh` doit rester vert, et
`shellcheck -S error bin/*.sh bin/factory` (la CI l'exige, voir
`.github/workflows/ci.yml`) ne doit signaler aucune erreur. Aucune valeur
d'infrastructure Brume (adresse locale, nom d'hote, identifiant personnel)
ne doit apparaitre dans `bin/`, `factory.mk`, `nix/` ou `skill/` :
`tests/hygiene.test.sh` le verifie a chaque run.

## Provenance et licence

Extrait de [Brume](https://github.com/Brume-ai) au SHA
`12ac9e92c00fe8ce71472ff3a06f2818d690f05e`, ou cet outillage a ete construit
et a paye ses lecons en production. Generalise pour etre consomme par
n'importe quel depot, sans dependance a l'infrastructure d'origine (adresses,
noms d'hote, comptes) : voir `tests/hygiene.test.sh` pour la garantie
automatisee.

Licence [AGPL-3.0-only](LICENSE).
