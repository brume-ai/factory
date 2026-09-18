#!/usr/bin/env python3
"""Extrait de Brume (tools/factory/gh-security-triage.py) au SHA 12ac9e92 ; generalise ici.
gh-security-triage.py — les alertes de sécurité GitHub deviennent des cartes.

POURQUOI CE SCRIPT EXISTE. Les onglets Security du dépôt sont un cimetière : 232
alertes Dependabot et 14 CodeQL y dormaient sans que personne ne soit envoyé.
Elles ne sont dans aucune file — ni `gh-next-issue` (qui lit les issues) ni
`gh-pr-attention` (qui lit les PR) ne les voient. Ce script les transpose en
issues, seule monnaie que l'usine sait dépenser.

L'UNITÉ DE TRAVAIL N'EST PAS L'ALERTE, et c'est la décision qui porte tout le
reste. Les 232 alertes Dependabot vivent dans SEPT lockfiles, et `aiohttp` en
porte 51 à lui seul : la réparation est un bump de lockfile qui en referme des
dizaines d'un coup. Une carte par alerte, ce serait 232 tours d'usine pour 7
commits — la file bloquée des semaines à rejouer le même geste.

  · Dependabot     → une carte par MANIFESTE   (le bump referme le lot)
  · Code scanning  → une carte par RÈGLE       (7 clear-text-logging = une passe)
  · Secret scanning→ une carte par ALERTE      (un secret exposé est un incident
                                                individuel, avec sa rotation ;
                                                grouper ferait rater le second)

ON NE LIT QUE LES SURFACES QUI ONT UNE API. « Security quality », « AI findings »
et « Malware » rendent 404 sur l'API REST aujourd'hui : il n'y a rien à
interroger, et prétendre les couvrir serait pire que de ne pas les couvrir. On
lit la SURFACE code-scanning et non le nom de l'outil — le jour où ces analyses
y publieront leurs résultats, elles entreront sans modifier une ligne.

LA FEATURE PERMANENTE DES ALERTES (`FACTORY_SECURITY_FEATURE`, résolue par
l'appelant comme les labels). Dans la v2 une carte sans issue Feature au-dessus
d'elle est sa propre MINI-FEATURE : une branche, une PR, un merge d'EVA, une
ligne de release — pour UNE alerte. Posée, la clé nomme une issue de type
Feature, ouverte, sous laquelle chaque carte créée ici est rattachée comme
sous-issue (GraphQL `addSubIssue`) : les alertes vivent alors sur UNE branche
`feature/<F>`, relues par lot. Vide, le comportement d'avant, et une ligne sur
stderr par tour qui le dit. Un rattachement refusé pose `needs-human` sur la
carte neuve (card-state.sh, comme gh-pr-attention.sh) plutôt que de la laisser
naître mini-feature en silence ; une feature configurée mais fermée, ou qui
n'est pas une Feature, est une configuration cassée : 3, avant toute carte.

LE TRANSPORT EST CURL, PAS URLLIB : le faux curl des tests tient lieu de
GitHub pour tous les scripts, et ce script était le seul qu'il ne pouvait pas
voir — « surface illisible → cartes laissées » n'était prouvé que par lecture.

Codes : 0 = terminé (avec ou sans changement) · 3 = mal configuré · 4 = la
feature permanente illisible par un raté passager (rien n'est créé, retenté).
"""

import json
import os
import subprocess
import sys
import tempfile
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
if not os.environ.get("GH_REPO"):
    print("gh-security-triage: GH_REPO absent de l'environnement (le pilote factory.mk le passe)",
          file=sys.stderr)
    sys.exit(3)
REPO = os.environ["GH_REPO"]


def label(var: str) -> str:
    """Le nom d'un label, tel que l'APPELANT l'a résolu. Aucun défaut ici.

    Ce script ne peut pas sourcer bin/lib.sh : c'est factory.mk qui résout les
    rôles par `label_get` et lui passe les noms (PRIO, BUSY, DONE, STAGED). Un
    `os.environ.get("…", "factory:priority")` serait un SECOND domicile pour le
    nom, invisible depuis factory.conf : renommer le label de priorité marcherait
    dans les six scripts shell et pas ici, et le triage poserait sa priorité sous
    l'ANCIEN nom — la carte de sécurité tomberait hors de la file que
    `gh-next-issue` lit, sans que rien ne le dise. C'est le défaut même que
    `label_get` existe pour supprimer, et l'écrire en Python le rendrait
    seulement plus difficile à voir.

    Le vide vaut l'absence : dans factory.mk la valeur passe par un `$(…)` qui
    avale le code 3 d'un rôle inconnu, et il n'en reste alors qu'une chaîne
    vide. Un label vide est pire qu'un label faux — `factory:` vide fait
    correspondre n'importe quoi côté GitHub comme côté grep.
    """
    v = os.environ.get(var)
    if not v:
        print(f"gh-security-triage: {var} absent de l'environnement "
              "(le pilote factory.mk le résout par label_get et le passe)",
              file=sys.stderr)
        sys.exit(3)
    return v


PRIORITY = label("PRIO")
# UNE SPEC PRISE, LIVRÉE OU INTÉGRÉE EST GELÉE : on n'y touche plus. Réécrire le
# corps sous les pieds de qui travaille dessus ferait diverger la PR en cours de
# sa propre carte, en silence.
# L'ÉTAT INTÉGRÉ EN FAIT PARTIE DEPUIS QUE LA RELEASE EXISTE. Une carte marquée
# « intégrée » est dans la branche de travail et attend d'être relue puis fermée
# par la release : son corps est précisément ce que l'humain relit. Le laisser
# hors du jeu gelé ferait réécrire, sous les yeux du relecteur et entre deux
# tours de ménage, la spec de ce qui est DÉJÀ intégré — la file de relecture ne
# dirait plus ce qui a été livré.
# BLOQUÉE ET EN ARBITRAGE AUSSI : ces deux-là portent une DÉCISION dans leur
# corps (« Bloquée par #N », la question posée à l'humain) que le PATCH d'un
# corps recomposé effaçait — la carte perdait son bloqueur, gh-unblock ne la
# rendait plus jamais à la file. Ils sont passés par l'appelant comme les
# autres ; absents, ils ne gèlent rien (un consommateur sur une ancienne
# recette n'est pas cassé, il est moins protégé, et ça se dit).
FROZEN = {label("BUSY"), label("DONE"), label("STAGED")}
for _opt in ("BLOCKED", "HUMAN"):
    if os.environ.get(_opt):
        FROZEN.add(os.environ[_opt])
    else:
        print(f"gh-security-triage: {_opt} absent de l'environnement — les cartes "
              "bloquées ou en arbitrage ne seront pas gelées (mettez factory.mk à jour)",
              file=sys.stderr)


def token() -> str:
    if os.environ.get("FACTORY_TOKEN"):
        return os.environ["FACTORY_TOKEN"]
    try:
        out = subprocess.run(
            ["bash", os.path.join(HERE, "gh-app-token.sh")],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError:
        sys.exit(3)
    return out.stdout.strip()


TOKEN = token()

SECURITY_FEATURE = (os.environ.get("FACTORY_SECURITY_FEATURE") or "").strip()
if SECURITY_FEATURE and not SECURITY_FEATURE.isdigit():
    print(f"gh-security-triage: FACTORY_SECURITY_FEATURE doit être le numéro d'une issue "
          f"de type Feature (« {SECURITY_FEATURE} »)", file=sys.stderr)
    sys.exit(3)


# `--dry-run` n'est pas un confort : ce script ÉCRIT sur le tableau, et une
# erreur de groupement s'y voit sous la forme de dizaines de cartes à supprimer
# une par une. On doit pouvoir lire ce qu'il ferait avant qu'il le fasse.
DRY = "--dry-run" in sys.argv
# Le dernier code HTTP vu par `api` (ou "000" sur un transport KO) : ce qui
# distingue, sur la feature permanente, un raté passager (4, retenté au tour
# suivant) d'une configuration cassée (3).
LAST_STATUS = None


def transient():
    return LAST_STATUS in (None, "000", "429") or str(LAST_STATUS).startswith("5")


def api(path, method="GET", data=None, paginate=False, absolute=False):
    """Appelle l'API. `paginate` suit les pages tant qu'elles sont pleines.

    `absolute` sort du prefixe /repos/<depot>/ : la recherche d'issues vit sous
    /search/issues et GraphQL sous /graphql, pas sous le depot.

    Rend None sur tout ce qui n'est pas un 2xx lisible — un refus HTTP, un
    transport qui flanche, un corps qui n'est pas du JSON — après l'avoir dit :
    une surface qu'on n'a pas pu lire est mise de côté, jamais lue comme vide.
    """
    if DRY and method != "GET":
        print(f"  [dry-run] {method} /{path}"
              + (f"  {json.dumps(data, ensure_ascii=False)[:120]}" if data else ""),
              file=sys.stderr)
        return {}
    # ON SUIT L'EN-TÊTE `Link`, JAMAIS UN COMPTEUR DE PAGES. L'API Dependabot
    # refuse `page` en 400 (« Pagination using the `page` parameter is not
    # supported ») : elle pagine par CURSEUR. Un compteur marchait donc sur deux
    # surfaces sur trois, et la troisième — celle qui porte 232 alertes — rendait
    # zéro carte en n'écrivant qu'une ligne sur stderr. Le `Link` est la seule
    # forme que les trois comprennent.
    global LAST_STATUS
    LAST_STATUS = None
    items = []
    url = (f"https://api.github.com/{path}" if absolute
           else f"https://api.github.com/repos/{REPO}/{path}")
    if paginate and "per_page=" not in url:
        url += ("&" if "?" in url else "?") + "per_page=100"
    while True:
        with tempfile.TemporaryDirectory(prefix="factory-security-") as directory:
            body_file, headers_file = directory + "/body", directory + "/headers"
            cmd = ["curl", "-sS", "--retry", "3", "--retry-delay", "2", "--retry-connrefused",
                   "--connect-timeout", "10", "--max-time", "60",
                   "-o", body_file, "-D", headers_file, "-w", "%{http_code}", "-X", method,
                   "-H", f"Authorization: Bearer {TOKEN}",
                   "-H", "Accept: application/vnd.github+json"]
            if data is not None:
                cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(data, ensure_ascii=False)]
            result = subprocess.run(cmd + [url], capture_output=True, text=True)
            if result.returncode:
                LAST_STATUS = "000"
                print(f"gh-security-triage: transport KO sur /{path} (curl {result.returncode})", file=sys.stderr)
                return None
            code = result.stdout.strip()
            LAST_STATUS = code
            with open(body_file, errors="replace") as source:
                raw = source.read()
            with open(headers_file, errors="replace") as source:
                link = " ".join(l.split(":", 1)[1] for l in source.read().splitlines() if l.lower().startswith("link:"))
        if not code.startswith("2"):
            # 403/404 sur une surface de sécurité veut presque toujours dire que
            # la fonctionnalité est désactivée sur le dépôt, ou que l'App n'a pas
            # la permission. On le NOMME et on continue sur les autres surfaces :
            # une surface muette ne doit pas emporter les deux autres.
            print(f"gh-security-triage: HTTP {code} sur /{path}", file=sys.stderr)
            if code in ("403", "404"):
                print("  → la surface est-elle activée, et l'App a-t-elle la "
                      "permission correspondante en lecture ?", file=sys.stderr)
            return None
        try:
            body = json.loads(raw or "null")
        except ValueError:
            print(f"gh-security-triage: réponse illisible sur /{path} (corps tronqué)", file=sys.stderr)
            return None
        if not paginate:
            return body
        if not isinstance(body, list):
            print(f"gh-security-triage: liste de forme inattendue sur /{path}", file=sys.stderr)
            return None
        items += body
        nxt = [p for p in link.split(",") if 'rel="next"' in p]
        if not nxt:
            return items
        url = nxt[0].split("<", 1)[1].split(">", 1)[0]


def sev_rank(s):
    return {"critical": 0, "high": 1, "medium": 2, "moderate": 2, "low": 3}.get(s, 4)


# --- les trois surfaces, chacune rendant {clé: carte} -------------------------

def from_dependabot():
    alerts = api("dependabot/alerts?state=open", paginate=True)
    if alerts is None:
        return None
    groups = {}
    for a in alerts:
        groups.setdefault(a["dependency"]["manifest_path"], []).append(a)
    cards = {}
    for manifest, xs in groups.items():
        xs.sort(key=lambda a: (sev_rank(a["security_advisory"]["severity"]),
                               a["dependency"]["package"]["name"]))
        worst = xs[0]["security_advisory"]["severity"]
        lines = []
        for a in xs:
            pkg = a["dependency"]["package"]["name"]
            sev = a["security_advisory"]["severity"]
            fix = next((v.get("first_patched_version") or {}).get("identifier")
                       for v in a["security_advisory"]["vulnerabilities"]
                       if v["package"]["name"] == pkg) or "—"
            lines.append(f"| `{pkg}` | {sev} | {fix} | [{a['security_advisory']['ghsa_id']}]"
                         f"({a['html_url']}) |")
        body = (
            f"`{manifest}` porte **{len(xs)} alertes Dependabot ouvertes** "
            f"(la plus grave : **{worst}**).\n\n"
            "La réparation est un **bump du lockfile**, pas une correction par "
            "alerte : c'est pourquoi cette carte porte le manifeste entier et non "
            "une vulnérabilité.\n\n"
            "| Paquet | Sévérité | Corrigé en | Avis |\n|---|---|---|---|\n"
            + "\n".join(lines) + "\n\n"
            "## Critères d'acceptation\n\n"
            f"- [ ] `{manifest}` est régénéré, et les alertes ci-dessus sont closes côté GitHub.\n"
            "- [ ] La suite de tests qui couvre ce composant passe sur base fraîche — "
            "un bump de dépendance casse en silence, c'est son mode d'échec normal.\n"
            "- [ ] Toute alerte laissée ouverte est **nommée dans la PR avec sa raison** "
            "(pas de correctif publié, montée majeure incompatible). Une alerte muette "
            "qu'on croit traitée est pire qu'une alerte ouverte.\n"
        )
        cards[f"dependabot:{manifest}"] = {
            "title": f"Dependabot — {len(xs)} alerte{'s' if len(xs) > 1 else ''} dans {manifest}",
            "body": body,
        }
    return cards


def from_code_scanning():
    alerts = api("code-scanning/alerts?state=open", paginate=True)
    if alerts is None:
        return None
    groups = {}
    for a in alerts:
        groups.setdefault(a["rule"]["id"], []).append(a)
    cards = {}
    for rule, xs in groups.items():
        r = xs[0]["rule"]
        sev = r.get("security_severity_level") or r.get("severity") or "—"
        lines = []
        for a in xs:
            loc = a["most_recent_instance"]["location"]
            lines.append(f"- [`{loc['path']}:{loc['start_line']}`]({a['html_url']})")
        body = (
            f"**{r.get('description') or rule}** — {len(xs)} occurrence(s), "
            f"sévérité **{sev}**, relevées par {xs[0]['tool']['name']}.\n\n"
            + (f"> {r['full_description']}\n\n" if r.get("full_description") else "")
            + "\n".join(lines) + "\n\n"
            "## Critères d'acceptation\n\n"
            "- [ ] Chaque occurrence est **tranchée**, pas seulement relue : corrigée, "
            "ou écartée sur l'API GitHub avec un motif écrit (`false positive` / "
            "`used in tests`). Une occurrence laissée ouverte sans motif revient "
            "à chaque sondage et reproduit cette carte indéfiniment.\n"
            "- [ ] Une occurrence en code de test se juge sur son objet, pas sur son "
            "chemin : un secret en dur dans une fixture reste un secret en dur.\n"
            "- [ ] Aucune règle n'est désarmée pour faire taire l'alerte. Si la règle "
            "est réellement inadaptée ici, dites dans la PR ce qu'elle cessera "
            "d'attraper ailleurs.\n"
        )
        cards[f"code-scanning:{rule}"] = {
            "title": f"CodeQL [{sev}] — {rule} ({len(xs)} occurrence{'s' if len(xs) > 1 else ''})",
            "body": body,
        }
    return cards


def from_secret_scanning():
    alerts = api("secret-scanning/alerts?state=open", paginate=True)
    if alerts is None:
        return None
    cards = {}
    for a in alerts:
        n = a["number"]
        # ON N'ÉCRIT JAMAIS LE SECRET DANS L'ISSUE. L'alerte le porte en clair
        # (`a["secret"]`) ; une issue est lisible par plus de monde que l'onglet
        # Security, et le dépôt deviendra public. On renvoie au lien.
        # LA SÉVÉRITÉ EST ÉCRITE, COMME SUR LES DEUX AUTRES SURFACES : un secret
        # exposé est un incident, et c'est ce mot que la vigie d'EVA relit pour
        # décider d'un ping.
        body = (
            f"**{a['secret_type_display_name']}** détecté "
            f"(validité rapportée : `{a.get('validity', 'inconnue')}`), "
            "sévérité **critical** — un secret exposé est un incident.\n\n"
            f"- Alerte : {a['html_url']}\n\n"
            "Le secret lui-même n'est pas reproduit ici : une issue se lit plus "
            "largement que l'onglet Security, et ce dépôt devient public.\n\n"
            "## Critères d'acceptation\n\n"
            "- [ ] Le secret est **révoqué chez son émetteur EN PREMIER**. Retirer la "
            "ligne du code ne révoque rien — la valeur reste valide, et elle reste "
            "dans l'historique git pour toujours.\n"
            "- [ ] La valeur de remplacement vit hors du dépôt (`.env` racine), et "
            "`.env.example` porte le commentaire + un substitut inoffensif.\n"
            "- [ ] L'alerte est close sur GitHub avec son motif.\n"
        )
        cards[f"secret-scanning:{n}"] = {
            "title": f"Secret exposé — {a['secret_type_display_name']} (alerte #{n})",
            "body": body,
        }
    return cards


# --- réconciliation ----------------------------------------------------------

def marker(key):
    return f"<!-- factory-security:{key} -->"


SURFACES = (("dependabot", from_dependabot),
            ("code-scanning", from_code_scanning),
            ("secret-scanning", from_secret_scanning))


def security_feature():
    """Le node id de la feature permanente, ou None sans clé. Lu UNE fois par
    tour, AVANT toute écriture : une feature fermée (sortie par une release) ou
    qui n'est pas une Feature ferait naître des cartes que gh-feature.py
    refuserait ou rattacherait à une feature que tout le monde croit finie —
    c'est une configuration cassée, 3."""
    if not SECURITY_FEATURE:
        print("gh-security-triage: FACTORY_SECURITY_FEATURE vide — chaque carte d'alerte créée "
              "sera sa propre mini-feature (une alerte = une branche, une PR, une ligne de "
              "release) ; posez le numéro d'une issue Feature permanente pour les rattacher",
              file=sys.stderr)
        return None
    feature = api(f"issues/{SECURITY_FEATURE}")
    if feature is None and transient():
        print(f"gh-security-triage: FACTORY_SECURITY_FEATURE=#{SECURITY_FEATURE} illisible ce tour-ci "
              f"(HTTP {LAST_STATUS or '?'}, raté passager) — rien n'est créé, on réessaie au prochain tour", file=sys.stderr)
        sys.exit(4)
    if not isinstance(feature, dict) or feature.get("number") != int(SECURITY_FEATURE):
        print(f"gh-security-triage: FACTORY_SECURITY_FEATURE=#{SECURITY_FEATURE} illisible "
              f"(HTTP {LAST_STATUS or '?'}) — configuration cassée, aucune carte créée", file=sys.stderr)
        sys.exit(3)
    kind = (feature.get("type") or {}).get("name") if isinstance(feature.get("type"), dict) else None
    if kind != "Feature" or feature.get("state") != "open" or not feature.get("node_id"):
        print(f"gh-security-triage: FACTORY_SECURITY_FEATURE=#{SECURITY_FEATURE} est "
              f"« {feature.get('state')} », de type « {kind or '-'} » : il faut une issue "
              "de type Feature OUVERTE — configuration cassée, aucune carte créée", file=sys.stderr)
        sys.exit(3)
    return feature["node_id"]


def attach(issue, feature_node):
    """Rattache la carte neuve à la feature permanente ; refusé → needs-human."""
    number = issue.get("number") if isinstance(issue, dict) else None
    if DRY or number is None:
        return
    reply = api("graphql", "POST", {
        "query": "mutation($p:ID!,$e:ID!){ addSubIssue(input:{issueId:$p, subIssueId:$e}) { issue { number } } }",
        "variables": {"p": feature_node, "e": issue.get("node_id")},
    }, absolute=True)
    if isinstance(reply, dict) and reply.get("data") and not reply.get("errors"):
        print(f"gh-security-triage: carte #{number} rattachée à la feature #{SECURITY_FEATURE}",
              file=sys.stderr)
        return
    reason = (f"carte d'alerte créée mais NON rattachée à la feature #{SECURITY_FEATURE} "
              f"(addSubIssue refusé : {json.dumps(reply, ensure_ascii=False)[:200] if reply else 'pas de réponse'}) : "
              "sans parent elle deviendrait sa propre mini-feature — rattachez-la à la main")
    print(f"gh-security-triage: #{number} — {reason}", file=sys.stderr)
    result = subprocess.run(["bash", os.path.join(HERE, "card-state.sh"), str(number), "needs-human", reason],
                            env=dict(os.environ, FACTORY_TOKEN=TOKEN))
    if result.returncode:
        print(f"gh-security-triage: needs-human n'a pas pu être posé sur #{number} "
              f"(card-state.sh {result.returncode})", file=sys.stderr)


def main():
    feature_node = security_feature()
    wanted = {}
    # UNE SURFACE MUETTE NE PROUVE RIEN. Un 403 (fonctionnalité désactivée, App
    # sans permission), un 404, un 5xx PASSAGER sur Dependabot rendaient « zéro
    # alerte » — et la réconciliation, plus bas, FERMAIT toutes les cartes de
    # cette surface comme « sans objet », y compris celles prises ou intégrées.
    # Un hoquet réseau effaçait la file de sécurité. Une surface qu'on n'a pas
    # pu lire est mise de côté : ni création, ni mise à jour, ni fermeture de
    # ses cartes ce tour-ci, et ça se dit.
    dead = []
    for name, source in SURFACES:
        cards = source()
        if cards is None:
            dead.append(name)
            print(f"gh-security-triage: surface « {name} » illisible ce tour-ci — "
                  "ses cartes sont laissées telles quelles", file=sys.stderr)
            continue
        wanted.update(cards)

    issues = api("issues?state=open&per_page=100", paginate=True)
    if issues is None:
        sys.exit(3)
    # L'endpoint /issues rend AUSSI les PR ; sans ce filtre on prendrait une PR
    # pour une carte de sécurité.
    issues = [i for i in issues if "pull_request" not in i]

    existing = {}
    for i in issues:
        body = i.get("body") or ""
        if "<!-- factory-security:" in body:
            key = body.split("<!-- factory-security:", 1)[1].split(" -->", 1)[0]
            existing[key] = i

    created = updated = closed = 0

    for key, card in sorted(wanted.items()):
        body = f"{marker(key)}\n\n{card['body']}"
        issue = existing.get(key)
        if issue is None:
            # ON REDEMANDE AVANT DE CRÉER, et cette seconde question n'est pas
            # une précaution de style.
            #
            # Mesuré sur open-source-draft : le 2026-09-09 à 15h10, ce triage a
            # créé #442 et #443 alors que #427 et #429 étaient OUVERTES, portaient
            # le même marqueur au caractère près, et le même label
            # `factory:delivered`. Même motif le 2026-08-11 et le 2026-09-05 : des
            # lots entiers recréés à la même seconde. La clé est pourtant stable
            # (`dependabot:<manifeste>`) et la pagination suit le `Link`.
            #
            # La cause n'est pas établie — la liste au-dessus est simplement
            # revenue sans les cartes qui existaient. Ce garde ne l'explique pas,
            # il la rend inoffensive : une recherche CIBLÉE sur le marqueur ne
            # dépend d'aucune liste, donc aucune liste incomplète ne peut la
            # tromper.
            #
            # Le coût d'un doublon n'est pas cosmétique : la file est opt-out,
            # donc une carte en double EST du travail en double — un tour d'agent
            # complet, une PR concurrente sur le même lockfile, et deux diffs qui
            # se marchent dessus à la relecture.
            # LA RECHERCHE PROPOSE, LE CORPS DÉCIDE. GitHub tokenise le code : une
            # requête sur `<!-- factory-security:dependabot:products/studio/backend/uv.lock -->`
            # rend AUSSI la carte de `products/studio/ee/backend` — vérifié, deux
            # résultats pour un marqueur. Se fier au compte annulerait des créations
            # légitimes, c'est-à-dire remplacer un doublon par une carte manquante,
            # qui est la panne la plus chère des deux : un doublon se voit, une
            # alerte jamais transposée ne se voit pas.
            q = urllib.parse.quote(f'repo:{REPO} is:issue is:open "{marker(key)}"')
            probe = api(f"search/issues?q={q}", absolute=True)
            twin = None
            for cand in (probe or {}).get("items", []) if isinstance(probe, dict) else []:
                if marker(key) in (cand.get("body") or ""):
                    twin = cand["number"]
                    break
            if twin is not None:
                print(f"gh-security-triage: carte #{twin} porte déjà ce marqueur — "
                      f"création annulée ({key})", file=sys.stderr)
                continue
            issue = api("issues", "POST", {"title": card["title"], "body": body,
                                           "labels": [PRIORITY]})
            if feature_node is not None:
                attach(issue, feature_node)
            created += 1
            print(f"gh-security-triage: carte créée — {card['title']}", file=sys.stderr)
            continue
        labels = {l["name"] for l in issue["labels"]}
        if (issue.get("body") or "").strip() == body.strip():
            continue
        if labels & FROZEN:
            # SPEC GELÉE. Quelqu'un travaille dessus ou l'a livrée : on ne réécrit
            # pas le corps sous ses pieds, on pose le delta en commentaire.
            api(f"issues/{issue['number']}/comments", "POST",
                {"body": "Le jeu d'alertes couvert par cette carte a changé depuis "
                         "sa prise. Corps laissé intact (travail en cours) — voir "
                         "l'onglet Security pour l'état courant."})
        else:
            api(f"issues/{issue['number']}", "PATCH",
                {"title": card["title"], "body": body})
        updated += 1
        print(f"gh-security-triage: carte #{issue['number']} mise à jour", file=sys.stderr)

    # SANS OBJET → FERMÉE. Une carte dont toutes les alertes ont disparu n'a plus
    # rien à livrer : le correctif est passé, ou la dépendance a bougé. La preuve
    # est mécanique (zéro alerte sur la surface), donc la fermeture l'est aussi.
    for key, issue in sorted(existing.items()):
        if key in wanted:
            continue
        if key.split(":", 1)[0] in dead:
            continue
        # UNE CARTE GELÉE NE SE FERME PAS D'ICI. Prise : un agent tient ce
        # worktree, et fermer sa carte sous ses pieds rend sa PR orpheline.
        # Livrée ou intégrée : c'est la RELEASE qui ferme, et seulement elle —
        # les alertes ont disparu parce que le correctif est dans la branche
        # de travail, ce qui est exactement l'état « attend la release ».
        labels = {l["name"] for l in issue["labels"]}
        if labels & FROZEN:
            print(f"gh-security-triage: carte #{issue['number']} n'a plus d'alerte "
                  "mais est prise, livrée, intégrée ou en attente — laissée à la release",
                  file=sys.stderr)
            continue
        api(f"issues/{issue['number']}/comments", "POST",
            {"body": "Fermée : plus aucune alerte ouverte sur cette surface. "
                     "Si elle reparaît, une carte neuve sera créée."})
        api(f"issues/{issue['number']}", "PATCH", {"state": "closed",
                                                  "state_reason": "completed"})
        closed += 1
        print(f"gh-security-triage: carte #{issue['number']} fermée (sans objet)",
              file=sys.stderr)

    print(f"gh-security-triage: {len(wanted)} surface(s) à traiter — "
          f"{created} créée(s), {updated} mise(s) à jour, {closed} fermée(s)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
