#!/usr/bin/env bash
# `factory doctor` — un faux dépôt consommateur, et les deux modes dessus.
#
# ZÉRO RÉSEAU, ZÉRO make, ZÉRO python3 : le docteur ne lit que des fichiers, des
# refs git locales et `factory.conf`. C'est délibéré et ça doit le rester —
# tests/run.sh rend un verdict PAR FICHIER, et un docteur qui dépendrait d'un
# outil absent ferait rougir ce fichier pour une raison qui n'est pas la sienne.
#
# CE QUE CE FICHIER PROUVE, DANS L'ORDRE :
#   1. le défaut : sans la clé, rien ne change pour un consommateur existant
#   2. pas de repli silencieux sur une faute de frappe
#   3. LE MÊME ARBRE, DEUX VERDICTS — c'est ce qui prouve que la clé gouverne
#   4. le docteur ne s'arrête pas au premier grief
#   5. point 1, ses quatre refus et SES DEUX FORMES LÉGITIMES
#   6. point 2, sans que le mécanisme d'un consommateur remonte dans la clé
#   7. point 3, y compris le clone qui ne suit qu'une branche
#   8. `--quiet` ne porte que les griefs et le verdict
#   9. l'aiguilleur mène bien au script, et l'aide le montre
. "$(dirname "$0")/helpers.sh"
t_setup

bash -n "$REPO/bin/doctor.sh"
bash -n "$REPO/bin/factory"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

WF="$TESTTMP/.github/workflows"
mkdir -p "$WF"

# --- le faux consommateur -----------------------------------------------------
# Il est CALQUÉ SUR UN VRAI : un `ci.yml` dont le job `deploy` porte
# « needs: <suite> » et un `if:` de niveau job, une étape qui distingue la
# production dans son shell, et un fermeur déclenché par la conclusion de la CI,
# filtré sur le tronc de l'usine. Un fixture inventé prouverait que le docteur
# accepte ce que le docteur accepte.
git init -q -b staging "$TESTTMP"
git -C "$TESTTMP" commit -q --allow-empty -m socle
git -C "$TESTTMP" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$TESTTMP" update-ref refs/remotes/origin/staging HEAD
git -C "$TESTTMP" update-ref refs/remotes/origin/main HEAD

cat > "$WF/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [staging, main]
  pull_request:
    branches: [main, staging]

jobs:
  pest:
    name: Pest
    runs-on: ubuntu-latest
    steps:
      - run: php artisan test
  deploy:
    name: Deploy
    needs: pest
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Trigger the deploy hooks
        env:
          BRANCH: ${{ github.ref_name }}
        run: |
          if [ "$BRANCH" = "main" ]; then
            echo "==> production"
          else
            echo "==> recette"
          fi
YAML

cat > "$WF/close.yml" <<'YAML'
name: Close deployed cards
on:
  workflow_run:
    workflows: ['CI']
    types: [completed]

permissions:
  contents: read
  issues: write

jobs:
  close:
    if: >-
      github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.head_branch == 'staging'
    runs-on: ubuntu-latest
    steps:
      - name: Close the cards this deployment shipped
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh issue close "$n" --repo "$GH_REPO" --reason completed
YAML

GREE='GH_REPO = o/r
FACTORY_GIT_NAME = usine
FACTORY_GIT_EMAIL = usine@example.invalid
FACTORY_TRUNK = staging
FACTORY_DELIVERY = trunk
FACTORY_PROD_TRUNK = main
FACTORY_DEPLOY_JOB = .github/workflows/ci.yml:deploy
FACTORY_CLOSE_WORKFLOW = .github/workflows/close.yml'

conf() { printf '%s\n' "$@" > "$TESTTMP/factory.conf"; }

# Joue le docteur et pose $rc / $out. `set +e` : le refus est le sujet du test,
# il ne doit pas tuer le test.
doc() {
  set +e
  out="$(bash "$REPO/bin/doctor.sh" "$@" 2>&1)"; rc=$?
  set -e
}

# --- 1. LE DÉFAUT, et c'est l'assertion la plus importante du fichier ---------
# Aucun FACTORY_DELIVERY nulle part. Un consommateur existant qui monte de
# version ne doit RIEN voir changer : le docteur n'exige aucune des trois clés
# du mode trunk, et sort en 0.
conf 'GH_REPO = o/r' 'FACTORY_GIT_NAME = usine' 'FACTORY_GIT_EMAIL = u@e' \
     'FACTORY_HUMAN_LOGIN = humain' 'FACTORY_BOT_LOGIN = bot'
doc
assert_rc 0 "$rc" "cle absente : le docteur n'exige rien et sort en 0"
assert_contains "$out" "livraison : pull-request" "et il annonce le mode par defaut"
assert_contains "$out" "ne s'appliquent pas" "et il DIT que les trois exigences ne portent pas"
assert_not_contains "$out" "FACTORY_DEPLOY_JOB" "aucune des trois cles n'est reclamee en pull-request"
assert_not_contains "$out" "FACTORY_CLOSE_WORKFLOW" "idem pour le fermeur"

# LES SECRETS NE SE REFUSENT PAS. Le `.env` est gitignore : ses cles sont
# normalement absentes du poste d'ou l'on tape `factory doctor`. Les exiger
# ferait sortir en 3 une installation saine a chaque appel — le refus a tort qui
# desarme la commande. Mesure sur un vrai consommateur avant d'ecrire ceci.
set +e
out="$(env -u FACTORY_TOKEN bash "$REPO/bin/doctor.sh" 2>&1)"; rc=$?
set -e
assert_rc 0 "$rc" "cles d'App absentes : signalees, jamais refusees"
assert_contains "$out" "GH_APP_ID / GH_APP_INSTALL_ID absentes" "et le signalement les nomme"

# --- 2. PAS DE REPLI SILENCIEUX ----------------------------------------------
# Une faute de frappe ne doit pas livrer en pull-request sans le dire.
conf 'GH_REPO = o/r' 'FACTORY_GIT_NAME = usine' 'FACTORY_GIT_EMAIL = u@e' \
     'FACTORY_DELIVERY = Trunk'
doc
assert_rc 3 "$rc" "FACTORY_DELIVERY = Trunk sort en 3"
assert_contains "$out" "Trunk" "et le message NOMME la valeur fautive"

# --- 3. LE MÊME ARBRE, DEUX VERDICTS -----------------------------------------
# C'est ce qui prouve que la CLÉ gouverne, et pas seulement qu'elle existe : les
# fichiers ne bougent pas, seule la clé change.
conf "$GREE"
doc
assert_rc 0 "$rc" "arbre gree pour trunk : rien a signaler"
assert_contains "$out" "livraison : trunk" "et il annonce le mode"
assert_contains "$out" "ne part qu'après « pest »" "1. le job depend de la suite, et le message NOMME de quoi"
assert_contains "$out" "ferme les cartes, et sur « staging »" "2. le fermeur ferme, et sur le bon tronc"
assert_contains "$out" "deux branches distinctes" "3. les deux troncs different"
assert_contains "$out" "corroboré" "3. et le job de deploiement nomme la production"

conf 'GH_REPO = o/r' 'FACTORY_GIT_NAME = usine' 'FACTORY_GIT_EMAIL = u@e' \
     'FACTORY_HUMAN_LOGIN = humain' 'FACTORY_BOT_LOGIN = bot' 'FACTORY_TRUNK = staging'
doc
assert_rc 0 "$rc" "LE MEME arbre sans la cle : rien n'est exige"
assert_contains "$out" "ne s'appliquent pas" "et il le dit"

# --- 4. IL NE S'ARRÊTE PAS AU PREMIER GRIEF ----------------------------------
# Trois manques, TROIS griefs dans la même sortie. Un docteur qui sort au
# premier se fait relancer trois fois de suite, et on cesse de le lancer.
conf 'GH_REPO = o/r' 'FACTORY_GIT_NAME = usine' 'FACTORY_GIT_EMAIL = u@e' \
     'FACTORY_TRUNK = staging' 'FACTORY_DELIVERY = trunk'
doc
assert_rc 3 "$rc" "trunk nu : refus"
assert_contains "$out" "1. rien ne déclare quel job de CI" "grief 1 nomme"
assert_contains "$out" "2. rien ne déclare quel workflow ferme" "grief 2 nomme"
assert_contains "$out" "3. le tronc de production n'est pas déclaré" "grief 3 nomme"
assert_contains "$out" "3 exigence(s) non satisfaite(s)" "et les trois sont comptes"
assert_contains "$out" "FACTORY_DEPLOY_JOB = <workflow>:<job>" "chaque refus dit COMMENT le satisfaire"

# --- 5. POINT 1 ---------------------------------------------------------------
p1() { conf "$GREE" "FACTORY_DEPLOY_JOB = $1"; doc; }

p1 '.github/workflows/absent.yml:deploy'
assert_rc 3 "$rc" "1. workflow inexistant : refus"
assert_contains "$out" "n'existe pas" "et il le dit"

p1 '.github/workflows/ci.yml:Deploy'
assert_rc 3 "$rc" "1. job inexistant (la casse compte) : refus"
assert_contains "$out" "le job « Deploy » n'existe pas" "et il nomme le job cherche"

p1 'ci.yml'
assert_rc 3 "$rc" "1. forme sans deux-points : refus"
assert_contains "$out" "n'a pas la forme" "et il rappelle la forme"

# LE REFUS À TORT QU'UNE CONTRE-LECTURE A DÉMONTRÉ, ET QUI EST FIXÉ ICI.
# `always()` sur une ÉTAPE — « publier le journal quoi qu'il arrive », l'un des
# motifs les plus répandus des workflows GitHub — n'a AUCUN effet sur la garde du
# job. Un docteur qui le cherchait dans tout le bloc refusait ce déploiement,
# donc arrêtait une usine parfaitement gréée. Sans cette assertion, rien
# n'empêche la régression de revenir.
cp "$WF/ci.yml" "$WF/ci-etape.yml"
cat >> "$WF/ci-etape.yml" <<'YAML'
      - name: Toujours publier le journal
        if: always()
        run: echo journal
YAML
p1 '.github/workflows/ci-etape.yml:deploy'
assert_rc 0 "$rc" "1. always() sur une ETAPE : accepte, c'est banal et sans effet"
assert_contains "$out" "ne part qu'après « pest »" "et la garde du job est toujours reconnue"

# LE VRAI POSITIF EST CONSERVÉ : `always()` sur le JOB, lui, fait partir le
# déploiement malgré une suite rouge.
sed 's/    if: github.event_name == .push./    if: always()/' "$WF/ci.yml" > "$WF/ci-job.yml"
p1 '.github/workflows/ci-job.yml:deploy'
assert_rc 3 "$rc" "1. always() sur le JOB : refus"
assert_contains "$out" "même quand la suite échoue" "et il dit pourquoi"

# `needs:` ÉCRIT APRÈS `steps:` reste vu. Rien n'oblige un job a ordonner ses
# cles, et couper le bloc a `steps:` aurait fabrique un refus a tort de plus.
sed '/^    needs: pest$/d' "$WF/ci.yml" > "$WF/ci-apres.yml"
printf '    needs: pest\n' >> "$WF/ci-apres.yml"
p1 '.github/workflows/ci-apres.yml:deploy'
assert_rc 0 "$rc" "1. needs: ecrit apres steps: est toujours vu"

# Un job qui ne dépend de rien.
sed '/^    needs: pest$/d' "$WF/ci.yml" > "$WF/ci-nu.yml"
p1 '.github/workflows/ci-nu.yml:deploy'
assert_rc 3 "$rc" "1. job sans needs et sans workflow_run : refus"
assert_contains "$out" "ne dépend d'aucune suite" "et il dit ce qu'il lui faut"

# LA DEUXIÈME FORME LÉGITIME : le déploiement vit dans un AUTRE workflow,
# déclenché par la conclusion de la CI. Sans elle, tous les consommateurs qui ne
# déploient pas depuis le workflow de tests se feraient refuser.
cat > "$WF/deploy.yml" <<'YAML'
name: Deploy
on:
  workflow_run:
    workflows: ['CI']
    types: [completed]

jobs:
  ship:
    if: github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy
YAML
p1 '.github/workflows/deploy.yml:ship'
assert_rc 0 "$rc" "1. workflow_run + conclusion success, sans needs : accepte"
assert_contains "$out" "conclusion « success »" "et il dit ce qui le garde"
assert_contains "$out" "ne mentionne pas « staging »" "et il SIGNALE, sans refuser, que le tronc n'apparait pas"

# --- 6. POINT 2 ---------------------------------------------------------------
p2() { conf "$GREE" "FACTORY_CLOSE_WORKFLOW = $1"; doc; }

conf 'GH_REPO = o/r' 'FACTORY_GIT_NAME = usine' 'FACTORY_GIT_EMAIL = u@e' \
     'FACTORY_TRUNK = staging' 'FACTORY_DELIVERY = trunk' 'FACTORY_PROD_TRUNK = main' \
     'FACTORY_DEPLOY_JOB = .github/workflows/ci.yml:deploy'
doc
assert_rc 3 "$rc" "2. cle absente : refus"
assert_contains "$out" "FACTORY_CLOSE_WORKFLOW = <chemin du workflow>" "et il dit quoi poser"

p2 '.github/workflows/absent.yml'
assert_rc 3 "$rc" "2. fichier declare mais absent : refus"

# LE FICHIER EXISTE ET NE FERME RIEN. Une declaration qu'on pose sans lire ne
# vaut rien : c'est tout l'interet de nommer un CHEMIN plutot que de cocher.
cat > "$WF/rien.yml" <<'YAML'
name: Rien
on:
  workflow_run:
    workflows: ['CI']
    types: [completed]
jobs:
  rien:
    runs-on: ubuntu-latest
    steps:
      - run: echo "conclusion == 'success'"
YAML
p2 '.github/workflows/rien.yml'
assert_rc 3 "$rc" "2. fichier qui ne ferme aucune carte : refus"
assert_contains "$out" "ne ferme aucune carte" "et il dit ce qu'il a cherche"

# LA POLITIQUE D'UN CONSOMMATEUR NE REMONTE PAS DANS LA CLÉ. Un fermeur declenche
# par `deployment_status` — qui prouve MIEUX que le commit a atteint la preprod
# qu'un `workflow_run`, lequel ne prouve que la reussite du job qui TIRE le
# hook — doit passer. Un docteur qui exigerait la forme d'un consommateur connu
# empecherait celui-ci de demarrer sa boucle.
cat > "$WF/close-deployment.yml" <<'YAML'
name: Close on deployment
on:
  deployment_status:

permissions:
  contents: read
  issues: write

jobs:
  close:
    if: github.event.deployment_status.state == 'success'
    runs-on: ubuntu-latest
    steps:
      - env:
          GH_TOKEN: ${{ github.token }}
        run: gh issue close "$n" --reason completed
YAML
p2 '.github/workflows/close-deployment.yml'
assert_rc 0 "$rc" "2. un fermeur declenche autrement est accepte"

# Un fermeur github-script, qui ferme par l'API et non par `gh`.
cat > "$WF/close-script.yml" <<'YAML'
name: Close via API
on:
  deployment_status:
permissions:
  issues: write
jobs:
  close:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v7
        with:
          script: await github.rest.issues.update({ issue_number: n, state: 'closed' })
YAML
p2 '.github/workflows/close-script.yml'
assert_rc 0 "$rc" "2. une fermeture par l'API est reconnue aussi"

# LE FILTRE DE BRANCHE DOIT NOMMER LE TRONC DE L'USINE. Un fermeur branche
# ailleurs ne ferme jamais rien, et ce silence-la ressemble a une file vide.
sed "s/head_branch == 'staging'/head_branch == 'preprod'/" "$WF/close.yml" > "$WF/close-ailleurs.yml"
p2 '.github/workflows/close-ailleurs.yml'
assert_rc 3 "$rc" "2. fermeur filtre sur une autre branche : refus"
assert_contains "$out" "pas sur « staging »" "et il nomme les deux branches"

# PERMISSIONS : un bloc `permissions:` REMPLACE les droits par defaut du jeton.
sed 's/^  issues: write$/  issues: read/' "$WF/close.yml" > "$WF/close-403.yml"
p2 '.github/workflows/close-403.yml'
assert_rc 3 "$rc" "2. permissions sans issues: write, avec le jeton par defaut : refus"
assert_contains "$out" "403" "et il dit ce qui se passerait a l'execution"

# … MAIS PAS QUAND LE JETON N'EST PAS CELUI DE GITHUB. Un jeton maison a des
# droits que rien ici ne peut lire : l'accuser serait deviner, et deviner faux
# une fois suffit a desarmer la commande.
sed 's/${{ github.token }}/${{ secrets.JETON_MAISON }}/' "$WF/close-403.yml" > "$WF/close-pat.yml"
p2 '.github/workflows/close-pat.yml'
assert_rc 0 "$rc" "2. jeton maison : signale, jamais refuse"
assert_contains "$out" "un jeton que cette commande ne sait pas lire" "et il dit pourquoi il ne tranche pas"

# --- 7. POINT 3 ---------------------------------------------------------------
p3() { conf "$GREE" "FACTORY_TRUNK = $1" "FACTORY_PROD_TRUNK = $2"; doc; }

conf 'GH_REPO = o/r' 'FACTORY_GIT_NAME = usine' 'FACTORY_GIT_EMAIL = u@e' \
     'FACTORY_TRUNK = staging' 'FACTORY_DELIVERY = trunk' \
     'FACTORY_DEPLOY_JOB = .github/workflows/ci.yml:deploy' \
     'FACTORY_CLOSE_WORKFLOW = .github/workflows/close.yml'
doc
assert_rc 3 "$rc" "3. cle absente : refus"
assert_contains "$out" "FACTORY_PROD_TRUNK = <branche" "et il dit quoi poser"

# LE CARACTÈRE QUI FAIT SAUTER LE POINT 3 : ici, la casse. `Main` et `main` sont
# deux branches pour git et la meme pour un humain presse.
p3 'main' 'Main'
assert_rc 3 "$rc" "3. meme tronc a la casse pres : refus"
assert_contains "$out" "EST le tronc de production" "et il le dit en toutes lettres"

p3 'staging' 'production'
assert_rc 3 "$rc" "3. tronc de production absent des refs : refus"
assert_contains "$out" "n'existe dans aucune ref" "et il dit comment le rendre verifiable"

# LE CLONE QUI NE SUIT QU'UNE BRANCHE ne PEUT PAS savoir que l'autre existe :
# refuser ici accuserait la configuration d'un defaut du clone.
git -C "$TESTTMP" config remote.origin.fetch '+refs/heads/staging:refs/remotes/origin/staging'
git -C "$TESTTMP" update-ref -d refs/remotes/origin/main
conf "$GREE"
doc
assert_rc 0 "$rc" "3. clone --single-branch : signale, jamais refuse"
assert_contains "$out" "ne suit qu'une branche" "et il dit comment le rendre verifiable"
git -C "$TESTTMP" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$TESTTMP" update-ref refs/remotes/origin/main HEAD

# LE MERGE AUTOMATIQUE EST UN SIGNALEMENT. Un workflow qui sait merger une PR
# peut etre la promotion automatisee — le geste humain a disparu — ou tout autre
# chose ; on nomme le fichier et on laisse un humain regarder.
cat > "$WF/promo.yml" <<'YAML'
name: Promotion
on: workflow_dispatch
jobs:
  promote:
    runs-on: ubuntu-latest
    steps:
      - run: gh pr merge --merge
YAML
conf "$GREE"; doc
assert_rc 0 "$rc" "3. un merge automatique ne refuse pas"
assert_contains "$out" "sait merger une pull request" "mais il est signale"
assert_contains "$out" "promo.yml" "et le fichier est nomme"

# … SAUF LES MONTÉES DE VERSION AUTOMATIQUES, extremement courantes et sans
# rapport avec la promotion. Un avertissement qu'on voit partout ne se lit plus
# nulle part, et il emporte les autres avec lui.
sed 's/^on: workflow_dispatch$/on: pull_request\njobs_note: dependabot/' "$WF/promo.yml" > "$WF/promo-dep.yml"
rm "$WF/promo.yml"
conf "$GREE"; doc
assert_rc 0 "$rc" "3. l'automerge de dependabot ne signale rien"
assert_not_contains "$out" "sait merger une pull request" "et il se tait vraiment"
rm "$WF/promo-dep.yml"

# --- 8. `--quiet` : les griefs et le verdict, RIEN D'AUTRE --------------------
# C'est le mode de la boucle. Un ✓ ou un avertissement imprime a chaque tour
# cesse d'etre lu au troisieme, et il emporte les refus avec lui.
conf "$GREE"; doc --quiet
assert_rc 0 "$rc" "--quiet sur un arbre gree : rc 0"
assert_eq "" "$out" "et sortie STRICTEMENT vide"

# UN ARBRE QUI PASSE MAIS QUI FAIT PARLER LE DOCTEUR. `deploy.yml` declenche un
# avertissement (« ne mentionne pas staging ») : sous --quiet il ne doit rien en
# rester. C'est l'assertion qui empeche `warn` de redevenir bavard — un
# avertissement imprime a chaque tour de boucle desarme les deux autres.
conf "$GREE" 'FACTORY_DEPLOY_JOB = .github/workflows/deploy.yml:ship'
doc; assert_rc 0 "$rc" "l'arbre passe"
assert_contains "$out" "ne mentionne pas" "et il avertit, en clair"
doc --quiet
assert_rc 0 "$rc" "--quiet : meme verdict"
assert_eq "" "$out" "et PAS UN MOT d'avertissement"

conf "$GREE" 'FACTORY_PROD_TRUNK = staging'; doc --quiet
assert_rc 3 "$rc" "--quiet sur un arbre casse : rc 3"
assert_contains "$out" "EST le tronc de production" "le grief est la"
assert_contains "$out" "branche de recette" "et le remede aussi"
assert_not_contains "$out" "✓" "aucun ✓ sous --quiet"
assert_not_contains "$out" "ne peut pas voir" "aucun angle mort sous --quiet"

# --- 9. L'AIGUILLEUR ----------------------------------------------------------
# `bin/factory` n'a aucune logique : il aiguille. Et son aide est extraite par
# une plage `sed` qui s'arrete a `factory ssh` — une ligne ajoutee APRES serait
# invisible sans erreur ni symptome. C'est ce que fixe la derniere assertion.
conf "$GREE"
set +e
out="$(bash "$REPO/bin/factory" doctor 2>&1)"; rc=$?
set -e
assert_rc 0 "$rc" "factory doctor mene bien au script"
assert_contains "$out" "factory doctor —" "et rend le rapport"

set +e
out="$(bash "$REPO/bin/factory" doctor --quiet 2>&1)"; rc=$?
set -e
assert_rc 0 "$rc" "factory doctor --quiet : l'argument traverse l'aiguilleur"
assert_eq "" "$out" "et le silence aussi"

set +e
out="$(bash "$REPO/bin/factory" doctor --bidon 2>&1)"; rc=$?
set -e
assert_rc 2 "$rc" "un argument inconnu sort en 2, comme une commande inconnue"

set +e
out="$(bash "$REPO/bin/factory" --help 2>&1)"; rc=$?
set -e
assert_rc 0 "$rc" "l'aide sort en 0"
assert_contains "$out" "factory doctor" "et elle LISTE doctor (plage sed de l'aide)"


# --- 10. LES QUATRE FORMES QUI FAISAIENT MENTIR LE DOCTEUR --------------------
# Un docteur qui analyse du YAML au `sed` ratera toujours une forme. Ce qui
# compte, c'est DE QUEL COTE il se trompe : un refus a tort le fait desactiver
# dans la semaine, un laisser-passer a tort ne coute qu'un filet. Les quatre cas
# ci-dessous ont ete demontres sur des fixtures reelles ; trois etaient des refus
# a tort, le quatrieme le seul laisser-passer qui comptait vraiment.

# (a) `needs:` en SEQUENCE DE BLOC — la forme des docs GitHub des qu'il y a plus
# d'une dependance. Un `sed` qui ne lit que la forme en ligne rend du vide, et le
# docteur accusait « ne depend d'aucune suite » un depot parfaitement gree.
cat > "$WF/needs-bloc.yml" <<'YAML'
name: CI
on:
  push:
    branches: [staging]
jobs:
  pest:
    runs-on: ubuntu-latest
    steps:
      - run: php artisan test
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: ./lint
  deploy:
    needs:
      - pest
      - lint
    runs-on: ubuntu-latest
    steps:
      - run: curl "$HOOK"
YAML
p1 '.github/workflows/needs-bloc.yml:deploy'
assert_rc 0 "$rc" "1. needs: en sequence de bloc est vu (pas de refus a tort)"
assert_contains "$out" "pest" "1. et le message nomme ce dont le job depend"

# (b) `if: ${{ success() || failure() }}` — un `always()` ecrit autrement. Le
# `needs:` est la, la dependance est la, et le deploiement part sur du ROUGE.
# C'est la panne meme que le point 1 existe pour empecher.
cat > "$WF/if-failure.yml" <<'YAML'
name: CI
on:
  push:
    branches: [staging]
jobs:
  pest:
    runs-on: ubuntu-latest
    steps:
      - run: php artisan test
  deploy:
    needs: pest
    if: ${{ success() || failure() }}
    runs-on: ubuntu-latest
    steps:
      - run: curl "$HOOK"
YAML
p1 '.github/workflows/if-failure.yml:deploy'
assert_rc 3 "$rc" "1. un if: qui tolere failure() est REFUSE"
assert_contains "$out" "failure()" "1. et le refus nomme ce qui cloche"

# (c) DEUX BRANCHES SUR LA MEME LIGNE. Un `.*` de tete est gourmand : il n'en
# gardait que la DERNIERE, et le docteur refusait un fermeur qui couvre pourtant
# le tronc de l'usine.
cat > "$WF/close-deux.yml" <<'YAML'
name: Close
on:
  workflow_run:
    workflows: ['CI']
    types: [completed]
permissions:
  issues: write
jobs:
  close:
    if: >-
      github.event.workflow_run.head_branch == 'staging' || github.event.workflow_run.head_branch == 'main'
    runs-on: ubuntu-latest
    steps:
      - env:
          GH_TOKEN: ${{ github.token }}
        run: gh issue close "$n" --reason completed
YAML
p2 '.github/workflows/close-deux.yml'
assert_rc 0 "$rc" "2. deux branches sur une ligne : celle du tronc est vue"

# (d) `permissions: write-all` DONNE `issues: write` — c'est la forme raccourcie
# documentee par GitHub. La refuser, c'est accuser un fermeur qui a tous les droits.
cat > "$WF/close-writeall.yml" <<'YAML'
name: Close
on:
  workflow_run:
    workflows: ['CI']
    types: [completed]
permissions: write-all
jobs:
  close:
    if: github.event.workflow_run.head_branch == 'staging'
    runs-on: ubuntu-latest
    steps:
      - env:
          GH_TOKEN: ${{ github.token }}
        run: gh issue close "$n" --reason completed
YAML
p2 '.github/workflows/close-writeall.yml'
assert_rc 0 "$rc" "2. permissions: write-all vaut issues: write"

echo ok
