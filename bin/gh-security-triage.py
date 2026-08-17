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

Codes : 0 = terminé (avec ou sans changement) · 3 = mal configuré.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
if not os.environ.get("GH_REPO"):
    print("gh-security-triage: GH_REPO absent de l'environnement (le pilote factory.mk le passe)",
          file=sys.stderr)
    sys.exit(3)
REPO = os.environ["GH_REPO"]
PRIORITY = os.environ.get("FACTORY_PRIORITY_LABEL", "factory:priority")
# Une carte prise par un agent, ou déjà livrée, a sa spec GELÉE : on n'y touche
# plus. Réécrire le corps sous les pieds de qui travaille dessus ferait diverger
# la PR en cours de sa propre carte, en silence.
FROZEN = {os.environ.get("FACTORY_BUSY_LABEL", "factory:in-progress"),
          os.environ.get("FACTORY_DONE_LABEL", "factory:delivered")}


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


# `--dry-run` n'est pas un confort : ce script ÉCRIT sur le tableau, et une
# erreur de groupement s'y voit sous la forme de dizaines de cartes à supprimer
# une par une. On doit pouvoir lire ce qu'il ferait avant qu'il le fasse.
DRY = "--dry-run" in sys.argv


def api(path, method="GET", data=None, paginate=False):
    """Appelle l'API. `paginate` suit les pages tant qu'elles sont pleines."""
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
    items = []
    url = f"https://api.github.com/repos/{REPO}/{path}"
    if paginate:
        url += ("&" if "?" in url else "?") + "per_page=100"
    while True:
        req = urllib.request.Request(
            url, method=method,
            data=json.dumps(data).encode() if data is not None else None,
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req) as r:
                body = json.loads(r.read() or "null")
                link = r.headers.get("Link", "")
        except urllib.error.HTTPError as e:
            # 403/404 sur une surface de sécurité veut presque toujours dire que
            # la fonctionnalité est désactivée sur le dépôt, ou que l'App n'a pas
            # la permission. On le NOMME et on continue sur les autres surfaces :
            # une surface muette ne doit pas emporter les deux autres.
            print(f"gh-security-triage: HTTP {e.code} sur /{path}", file=sys.stderr)
            if e.code in (403, 404):
                print("  → la surface est-elle activée, et l'App a-t-elle la "
                      "permission correspondante en lecture ?", file=sys.stderr)
            return None
        if not paginate:
            return body
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
        return {}
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
        return {}
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
        return {}
    cards = {}
    for a in alerts:
        n = a["number"]
        # ON N'ÉCRIT JAMAIS LE SECRET DANS L'ISSUE. L'alerte le porte en clair
        # (`a["secret"]`) ; une issue est lisible par plus de monde que l'onglet
        # Security, et le dépôt deviendra public. On renvoie au lien.
        body = (
            f"**{a['secret_type_display_name']}** détecté "
            f"(validité rapportée : `{a.get('validity', 'inconnue')}`).\n\n"
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


def main():
    wanted = {}
    for source in (from_dependabot, from_code_scanning, from_secret_scanning):
        wanted.update(source())

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
            api("issues", "POST", {"title": card["title"], "body": body,
                                   "labels": [PRIORITY]})
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
