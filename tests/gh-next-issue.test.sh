#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
# t_setup unset deja FACTORY_MILESTONE et les sept cles de label : ce fichier
# mesure QUI est dans la file, et un nom de label exporte par le shell qui lance
# la suite ferait passer au vert des cas qui ne prouvent plus rien. Rien a unset
# de plus ici : un second endroit ou poser la meme regle finirait par diverger.

export GH_REPO="o/r"
S="$REPO/bin/gh-next-issue.sh"
P="$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.json"
B="$FAKE_HTTP_DIR/repos_o_r_issues_state_open_labels_factory_in-progress_per_page_100.json"
I="$FAKE_HTTP_DIR/repos_o_r_issues_state_open_per_page_100.json"
C="$FAKE_HTTP_DIR/calls.log"

# a) GH_REPO absent -> 3
set +e; (unset GH_REPO; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "sans GH_REPO le sondage sort en 3"

# b) file vide -> 1
printf '[]' > "$P"; printf '[]' > "$B"; printf '[]' > "$I"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "file vide = 1"

# c) une issue ouverte sans label -> son numero
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "issue nue prise"

# d) issue bloquee -> 1 (mise de cote)
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:blocked"}]}]' > "$I"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "issue bloquee ecartee"

# e) priorite : la plus recente prioritaire passe devant la plus ancienne nue
printf '[{"number":7,"created_at":"2026-01-01","labels":[]},{"number":9,"created_at":"2026-02-01","labels":[{"name":"factory:priority"}]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "9" "$n" "factory:priority passe devant"

# f) HTTP 500 sur les pulls -> 4 (rate passager)
printf '500' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "HTTP 500 = rate passager (4)"
rm -f "$FAKE_HTTP_DIR"/*.code

# g) HTTP 404 -> 3 (mal configure)
printf '404' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "HTTP 404 = configuration (3)"
rm -f "$FAKE_HTTP_DIR"/*.code

# h) L'INDICE DE PERMISSION NE DEPEND PLUS DE L'ENDPOINT. Le motif qui le
#    choisissait selon le chemin envoyait chercher « Actions: Read » sur le 403
#    des ISSUES de tout depot nomme `actions/...` -- github.com/actions est une
#    vraie organisation -- soit la classe de mauvais diagnostic que ce script
#    existe pour supprimer (cinq arrets d'usine en sept jours). Ce script ne
#    touche plus qu'une surface : l'indice est unique, donc toujours juste.
printf '403' > "$FAKE_HTTP_DIR/repos_actions_runner_pulls_state_open_per_page_100.code"
set +e; msg="$(GH_REPO=actions/runner bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "un 403 reste une erreur de configuration"
assert_contains "$msg" "Issues: Read and write" "un depot nomme actions/ n'est pas l'endpoint Actions"
assert_not_contains "$msg" "Actions: Read" "et on ne l'envoie pas chercher la mauvaise permission"
rm -f "$FAKE_HTTP_DIR"/*.code

# --- CE QUI RETIRE UNE CARTE DE LA FILE, DANS LE MODELE DE RELEASE ------------

# i) une PR ouverte sur card/7 retire la carte : le travail est fait, il attend
#    la CI et le merge automatique. Un agent neuf le referait.
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
printf '[{"head":{"ref":"card/7"}}]' > "$P"
printf '[]' > "$B"
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "une PR ouverte retire #7 de la file"
# ... et elle ne disparait pas en silence : « rien a faire » se justifie TOUJOURS.
# Sans cette phrase, une carte ouverte ecartee par sa seule PR faisait dire au
# script « aucune issue ouverte -- le tableau est reellement draine », un mensonge
# sur le seul tableau que l'humain regarde.
assert_contains "$msg" "déjà livrées (PR ouverte)" "la carte livree est nommee avant la justification"
assert_contains "$msg" "#7" "la justification nomme la carte ecartee par sa PR"
assert_not_contains "$msg" "réellement drainé" "un tableau non vide n'est jamais annonce comme draine"

# j) LE SEPTIEME ETAT. `factory:staged` = integree a la branche de travail, elle
#    attend la release. C'est la file de RELECTURE, pas la file de travail : la
#    rendre a un agent le ferait repartir sur un travail deja integre.
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:staged"}]}]' > "$I"
printf '[]' > "$P"
: > "$C"
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "factory:staged retire la carte de la file de travail"
assert_contains "$msg" "en attente de la release" "la carte integree se dit comme telle"
assert_contains "$msg" "#7" "la justification la nomme"
# LA JUSTIFICATION RELIT LA REPONSE QUI A DECIDE, PAS UNE SECONDE. Entre deux
# requetes une carte change d'etat, et le tour expliquerait alors un tableau que
# le filtre n'a jamais vu -- plus une requete de plus a chaque tour draine, qui
# sont justement les tours les plus nombreux. Le journal est PRE-CREE ci-dessus :
# compter sur un fichier absent ne prouverait rien.
assert_eq "1" "$(grep -c 'issues?state=open&per_page=100' "$C")" \
  "un seul appel a la liste des issues par tour, justification comprise"

# k) factory:delivered ecarte toujours, et il ne se confond pas avec staged :
#    deux etats successifs, deux mots, deux phrases de justification.
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:delivered"}]},{"number":8,"created_at":"2026-01-02","labels":[{"name":"factory:staged"}]}]' > "$I"
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "livree et integree sont toutes deux hors file"
assert_contains "$msg" "#7" "la carte livree est nommee"
assert_contains "$msg" "#8" "la carte integree est nommee"
assert_contains "$msg" "merge automatique" "livree = PR ouverte, en attente d'integration"
assert_contains "$msg" "file de relecture" "integree = la file que l'humain relit"

# l) LA PHRASE DE SORTIE EST UNIQUE, et elle enumere les raisons du seul modele
#    qui reste. Elle en enumerait deux jeux selon un mode qui n'existe plus.
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; set -e
assert_contains "$msg" "rien à faire (toute carte ouverte est livrée, intégrée, bloquée, hors jalon ou en attente d'un humain)" "une seule phrase de sortie, et elle nomme les cinq raisons"

# --- LE CHEMIN DE LECTURE DES LABELS : factory.conf DOIT SUFFIRE --------------
# Ce que ces cas tiennent : les noms de labels etaient lus par expansion directe
# de l'environnement, si bien que les poser dans factory.conf ne suffisait PAS --
# il fallait AUSSI les exporter, et le renommage qui ne marchait qu'a moitie
# etait silencieux. Un label mal nomme sort une carte de la file pour toujours.

# m) le label integre se renomme, et la carte qui porte le NOUVEAU nom est ecartee
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"usine:en-recette"}]}]' > "$I"
make_conf 'FACTORY_STAGED_LABEL = usine:en-recette'
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "FACTORY_STAGED_LABEL se lit dans factory.conf"
# ... et celle qui porte l'ANCIEN nom redevient du travail : sans cette moitie, un
# test passerait sur un script qui ecarte les deux noms a la fois.
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:staged"}]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "le nom par defaut ne vaut plus rien une fois la cle renommee"

# n) le label de priorite aussi : il etait lu avec un DEFAUT python, donc un
#    second nom invisible depuis factory.conf.
printf '[{"number":7,"created_at":"2026-01-01","labels":[]},{"number":9,"created_at":"2026-02-01","labels":[{"name":"usine:urgent"}]}]' > "$I"
make_conf 'FACTORY_PRIORITY_LABEL = usine:urgent'
n="$(bash "$S" 2>/dev/null)"
assert_eq "9" "$n" "FACTORY_PRIORITY_LABEL se lit dans factory.conf"
printf '[{"number":7,"created_at":"2026-01-01","labels":[]},{"number":9,"created_at":"2026-02-01","labels":[{"name":"factory:priority"}]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "le defaut python de la priorite a disparu avec le second nom"

# o) le label de prise gouverne l'URL elle-meme : la requete part sur le nom
#    declare, pas sur un defaut en dur.
printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"usine:prise"}]}]' > "$I"
cp "$I" "$FAKE_HTTP_DIR/repos_o_r_issues_state_open_labels_usine_prise_per_page_100.json"
printf '[]' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_head_o_card_5_per_page_1.json"
make_conf 'FACTORY_BUSY_LABEL = usine:prise'
: > "$C"
n="$(bash "$S" 2>/dev/null)"
assert_eq "5" "$n" "la carte prise est reprise sous le nom declare"
assert_contains "$C" "labels=usine:prise" "la requete des cartes prises porte le nom declare"
assert_file_lacks "$C" "labels=factory:in-progress" "et plus le defaut en dur"
make_conf

# --- LE VERROU : PRISE + PR OUVERTE vs PRISE SANS PR -------------------------

# p) carte prise dont la PR est ouverte : elle attend son integration, pas un
#    agent. La sonde carte par carte est la seule qui voie au-dela des 100
#    premieres PR, donc la seule qui tranche.
printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"}]}]' > "$I"
cp "$I" "$B"; printf '[]' > "$P"
printf '[{"number":42}]' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_head_o_card_5_per_page_1.json"
: > "$C"
set +e; n="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e
assert_contains "$TESTTMP/err" "attend son intégration" "la carte livree est nommee comme telle, pas reprise en silence"
assert_contains "$TESTTMP/err" "PR #42" "la PR qui tranche est citee par son numero"
assert_contains "$C" "pulls?state=open&head=o:card/5" "la sonde porte sur la branche de CETTE carte, prefixee du proprietaire"
# CE QUE CE CAS NE PROUVE PAS, ET POURQUOI IL L'ECRIT QUAND MEME : la carte est
# ensuite SERVIE (rc 0), car ce qui la retire de la file c'est la liste GLOBALE
# des PR, pas cette sonde -- qui, elle, ne fait que parler. Fixe ici pour qu'on le
# voie, pas pour qu'on l'approuve.
assert_rc 0 "$rc" "la sonde par carte parle, mais ne retire pas la carte de la file"
assert_eq "5" "$n" "... et c'est la liste globale des PR qui le ferait"

# q) meme carte prise, aucune PR nulle part : c'est un tour tue en route, il se
#    reprend, et il se DIT autrement.
printf '[]' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_head_o_card_5_per_page_1.json"
: > "$C"
set +e; n="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 0 "$rc" "un tour interrompu se reprend"
assert_eq "5" "$n" "la carte prise sans PR revient a un agent"
assert_contains "$TESTTMP/err" "aucune PR" "la reprise dit ce qui l'autorise"

# r) UNE CARTE PRISE PUIS MISE DE COTE NE GELE PAS LA FILE, ET ELLE N'EST MEME
#    PAS SONDEE. Les cartes prises et la file generale passaient par DEUX filtres
#    jumeaux -- memes labels, meme rang, meme defaut de priorite -- qu'il fallait
#    penser a editer tous les deux. `factory:staged` est precisement l'etat qui
#    arrive apres : une carte restee `in-progress` ET integree n'attend plus
#    aucun agent, et la sonde de sa PR serait une requete pour rien.
for lab in factory:staged factory:needs-human factory:blocked factory:epic; do
  printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"},{"name":"%s"}]},{"number":7,"created_at":"2026-02-01","labels":[]}]' "$lab" > "$I"
  printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"},{"name":"%s"}]}]' "$lab" > "$B"
  : > "$C"
  set +e; n="$(bash "$S" 2>/dev/null)"; rc=$?; set -e
  assert_rc 0 "$rc" "une carte prise puis $lab ne gele pas la file"
  assert_eq "7" "$n" "la carte neuve part malgre la carte $lab restee en cours"
  assert_file_lacks "$C" "head=o:card/5" "rien a departager ($lab) : la PR de la carte mise de cote n'est pas sondee"
done

# --- LE JALON ----------------------------------------------------------------
# Retirer une carte d'une version, c'est la deplacer vers le jalon suivant : un
# clic, et la file obeit au tour d'apres. C'est le sondage qui le fait respecter,
# pas la release -- une carte deja integree ne se retire plus qu'au revert.
printf '[]' > "$P"; printf '[]' > "$B"

# s) une carte d'un AUTRE jalon est hors file ; celle du jalon courant part.
printf '[{"number":7,"created_at":"2026-01-01","labels":[],"milestone":{"title":"v2.0","number":2}},{"number":9,"created_at":"2026-02-01","labels":[],"milestone":{"title":"v1.4","number":1}}]' > "$I"
make_conf 'FACTORY_MILESTONE = v1.4'
n="$(bash "$S" 2>/dev/null)"
assert_eq "9" "$n" "le jalon courant sert, meme contre une carte plus ancienne"

# t) ... et la carte ecartee SE DIT. Un deplacement de jalon qui fait disparaitre
#    une carte du tableau sans un mot est exactement la mise de cote silencieuse
#    que le bloc de justification existe pour empecher.
printf '[{"number":7,"created_at":"2026-01-01","labels":[],"milestone":{"title":"v2.0","number":2}}]' > "$I"
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "seule une carte d'un autre jalon = rien a faire"
assert_contains "$msg" "autre jalon" "la carte hors jalon est nommee comme telle"
assert_contains "$msg" "v1.4" "et le jalon courant est cite"
assert_contains "$msg" "#7" "la carte ecartee est nommee"

# u) UNE CARTE SANS JALON RESTE EN FILE. La file est OPT-OUT : exiger un jalon
#    ferait d'un oubli d'etiquetage une carte invisible et par defaut -- le
#    `factory:ready` qu'on vient justement de supprimer. Ce qui ecarte, c'est un
#    jalon AUTRE, pas l'absence de jalon.
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "une carte sans jalon n'est pas exclue par un jalon configure"
printf '[{"number":7,"created_at":"2026-01-01","labels":[],"milestone":null}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "milestone:null non plus (c'est ce que GitHub renvoie)"

# v) LE JALON EST INERTE QUAND IL N'EST PAS CONFIGURE. Vide veut dire AUCUN
#    FILTRE, pas « jalon sans nom » : chez un consommateur qui n'utilise pas les
#    jalons, ce script doit se comporter au byte pres comme avant que la cle
#    existe. Memes fixtures des deux cotes, meme carte servie, et le JOURNAL DES
#    APPELS compare octet par octet -- c'est lui qui prouve « aucune requete de
#    plus », qu'aucune assertion sur stdout ne pourrait tenir.
printf '[{"number":9,"created_at":"2026-02-01","labels":[],"milestone":{"title":"v1.4","number":1}},{"number":11,"created_at":"2026-03-01","labels":[]}]' > "$I"
make_conf
: > "$C"
sans="$(bash "$S" 2>/dev/null)"
cp "$C" "$TESTTMP/calls.sans"
make_conf 'FACTORY_MILESTONE = v1.4'
: > "$C"
avec="$(bash "$S" 2>/dev/null)"
cp "$C" "$TESTTMP/calls.avec"
assert_eq "$sans" "$avec" "avec ou sans jalon, la meme carte est servie"
assert_eq "9" "$avec" "... et c'est bien celle du jalon"
cmp -s "$TESTTMP/calls.sans" "$TESTTMP/calls.avec" \
  || { echo "le filtrage par jalon a change les requetes : il doit etre purement cote client" >&2; \
       diff "$TESTTMP/calls.sans" "$TESTTMP/calls.avec" >&2; exit 1; }
assert_file_lacks "$TESTTMP/calls.avec" "milestone" "le jalon ne part jamais dans une URL"

# w) sans jalon configure, une carte de N'IMPORTE QUEL jalon reste en file : rien
#    ne change de comportement, pas seulement rien ne s'ajoute en requetes.
printf '[{"number":7,"created_at":"2026-01-01","labels":[],"milestone":{"title":"v9.9","number":9}}]' > "$I"
make_conf
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "sans FACTORY_MILESTONE, aucun jalon n'ecarte quoi que ce soit"
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; set -e
assert_not_contains "$msg" "autre jalon" "et la justification ne parle pas d'un filtre qui n'existe pas"

# x) le jalon se lit dans factory.conf comme toutes les cles, commentaire de fin
#    de ligne compris : conf_get lit l'environnement EN PREMIER et n'ouvre alors
#    aucun fichier, un test qui ne passerait que par l'environnement ne prouverait
#    pas qu'il se lit la ou le consommateur l'ecrit.
printf '[{"number":7,"created_at":"2026-01-01","labels":[],"milestone":{"title":"v2.0","number":2}},{"number":9,"created_at":"2026-02-01","labels":[],"milestone":{"title":"v1.4","number":1}}]' > "$I"
make_conf 'FACTORY_MILESTONE = v1.4   # la version en cours'
n="$(bash "$S" 2>/dev/null)"
assert_eq "9" "$n" "un commentaire en fin de ligne ne casse pas le jalon"
n="$(FACTORY_MILESTONE=v2.0 bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "l'environnement gagne sur factory.conf"
make_conf

echo ok
