#!/usr/bin/env python3
"""gh-feature.py — la feature d'une carte, lue dans la chaîne des parents (docs/v2-feature.md § 1, D1).

Une carte est une sous-issue ; on remonte `parent_issue_url` jusqu'à une issue
de type « Feature » : c'est la feature. Une chaîne sans Feature fait de la
RACINE de la chaîne une MINI-FEATURE (même flux, pas de second chemin vers la
production) : une carte sans parent est sa propre feature, et ses sous-issues
(une remarque transformée, une refacto carvée) sont des cartes sur sa branche,
servies après elle. Une issue de type Feature n'est jamais une carte ; une
issue qui a des sous-issues est un lot, jamais une carte — sauf la racine
d'une mini-feature.

UNE LECTURE EN ÉCHEC N'EST JAMAIS « PAS DE PARENT ». Un 404, un 5xx, un corps
tronqué sur `issues/<n>` sortent en 3 ou 4 comme gh-dependencies.py — jamais en
« la carte est orpheline », qui ferait naître une branche `feature/<carte>` à
côté de la vraie feature, en silence. Même règle sur la liste ouverte : un objet
qui ne PORTE PAS la clé `parent_issue_url`, `type` ou `sub_issues_summary` (une
réponse de liste qui ne les rendrait pas) est relu par `issues/<n>`, il n'est
pas lu comme « null ».

Deux modes, un seul lecteur — le transport est celui de gh-dependencies.py :

  gh-feature.py of <repo> <carte>
      imprime un objet JSON : card, feature, mini (bool), chain (les numéros de
      la carte vers le haut), card_issue et feature_issue (les réponses REST).
      3 si la carte est elle-même une Feature, si un parent est hors dépôt, ou
      si la chaîne dépasse la profondeur que GitHub permet.

  gh-feature.py rank <repo>
      lit sur stdin {"open": [issues ouvertes], "candidates": [numéros]} et
      imprime les candidates ORDONNÉES (D3), moins les LOTS — une issue qui a
      des sous-issues n'est pas une carte, ses cartes sont le travail :
      (1) `factory:priority` sur la carte, (2) sur sa feature, (3) la position
      dans `sub_issues` de chaque parent, du haut vers le bas (lot puis carte),
      (4) le numéro. Entre deux
      features de même priorité, la plus ancienne (numéro le plus bas) passe
      devant : une feature se finit avant que la suivante commence, et c'est ce
      qui rend la relecture par lot possible. Une carte déjà prise (BUSY) passe
      devant tout : c'est le tour interrompu, son répertoire de tour l'attend.
      PRIO et BUSY (noms de label) viennent de l'environnement, sans défaut —
      comme gh-security-triage.py, pour la même raison. MILESTONE (vide = aucun
      filtre) écarte une carte d'un autre jalon ; une carte sans jalon HÉRITE
      celui de sa feature.

Codes : 0 · 3 = refus de l'API ou données incohérentes · 4 = raté passager.
"""
import importlib.util
import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("gh_dependencies", os.path.join(_HERE, "gh-dependencies.py"))
_deps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_deps)
request, LookupFailure = _deps.request, _deps.LookupFailure

FEATURE_TYPE = "Feature"
# GitHub borne la hiérarchie des sous-issues à huit niveaux ; au-delà, c'est
# une boucle ou une donnée cassée, pas une feature plus profonde.
MAX_DEPTH = 8


class Reader:
    """Lit les issues d'un dépôt avec un cache : un parent commun n'est lu qu'une fois."""

    def __init__(self, repo, known=()):
        self.repo = repo
        self.cache = {}
        self.sub_issues = {}
        for issue in known:
            if self._complete(issue):
                self.cache[issue["number"]] = issue

    @staticmethod
    def _complete(issue):
        # Les clés doivent être PRÉSENTES, même à null : une liste qui ne les
        # rend pas ne dit rien du parent ni des enfants, et on relit alors
        # l'issue seule.
        return (isinstance(issue, dict) and isinstance(issue.get("number"), int)
                and "parent_issue_url" in issue and "type" in issue and "sub_issues_summary" in issue)

    def issue(self, number):
        if number not in self.cache:
            data, _ = request("repos/%s/issues/%s" % (self.repo, number))
            if not self._complete(data) or data["number"] != number:
                raise LookupFailure("issue #%s illisible (number, parent_issue_url ou type absents)" % number, 3)
            self.cache[number] = data
        return self.cache[number]

    def parent_of(self, issue):
        url = issue.get("parent_issue_url")
        if url is None:
            return None
        if not isinstance(url, str):
            raise LookupFailure("parent_issue_url illisible sur #%s" % issue.get("number"), 3)
        m = re.fullmatch(r"https://api\.github\.com/repos/([^/]+/[^/]+)/issues/(\d+)", url)
        if not m:
            raise LookupFailure("parent_issue_url inattendu sur #%s : %s" % (issue.get("number"), url), 3)
        if m.group(1).lower() != self.repo.lower():
            raise LookupFailure("#%s a un parent hors dépôt (%s) : une feature vit dans le dépôt de ses cartes" % (issue.get("number"), url), 3)
        return int(m.group(2))

    def chain(self, number):
        """Les numéros de la carte vers le haut, parent après parent."""
        out, seen = [], set()
        current = number
        while current is not None:
            if current in seen or len(out) >= MAX_DEPTH:
                raise LookupFailure("chaîne de parents cyclique ou plus profonde que %d au-dessus de #%s" % (MAX_DEPTH, number), 3)
            seen.add(current)
            out.append(current)
            current = self.parent_of(self.issue(current))
        return out

    def children(self, number):
        """Les sous-issues de #number, dans l'ordre de priorité que GitHub rend."""
        if number not in self.sub_issues:
            path = "repos/%s/issues/%s/sub_issues?per_page=100" % (self.repo, number)
            prefix = path.split("?", 1)[0] + "?"
            acc, pages = [], 0
            while path:
                if pages >= 20 or not path.startswith(prefix):
                    raise LookupFailure("pagination des sous-issues de #%s incomplète" % number)
                page, path = request(path)
                if not isinstance(page, list):
                    raise LookupFailure("liste des sous-issues de #%s illisible" % number)
                acc.extend(page)
                pages += 1
            numbers = []
            for child in acc:
                if not isinstance(child, dict) or not isinstance(child.get("number"), int):
                    raise LookupFailure("sous-issue de #%s illisible" % number)
                numbers.append(child["number"])
            self.sub_issues[number] = numbers
        return self.sub_issues[number]

    def position(self, parent, child):
        siblings = self.children(parent)
        if child in siblings:
            return siblings.index(child)
        # Absente de la liste de son parent : une incohérence de l'index, pas un
        # refus — elle passe en dernier, et on le dit.
        print("gh-feature: #%s ne figure pas dans les sous-issues de #%s — classée en dernier" % (child, parent), file=sys.stderr)
        return len(siblings)


def is_feature(issue):
    t = issue.get("type")
    return isinstance(t, dict) and t.get("name") == FEATURE_TYPE


def is_lot(issue):
    """Une issue qui a des sous-issues est un LOT (ou une feature), jamais une carte :
    la hiérarchie utile est Feature → lot → carte, et le travail, ce sont les feuilles."""
    s = issue.get("sub_issues_summary")
    if s is None:
        return False
    if not isinstance(s, dict) or type(s.get("total")) is not int:
        raise LookupFailure("sub_issues_summary illisible sur #%s" % issue.get("number"), 3)
    return s["total"] > 0


def feature_of(reader, chain):
    """(F, mini) : la première Feature en remontant ; sans Feature, la RACINE de la chaîne.

    La racine, pas la carte : une carte orpheline #50 qui reçoit une sous-issue
    #60 (une remarque sur sa PR, une refacto carvée) reste la mini-feature, et
    #60 est une carte SUR feature/50 — sinon #60 ouvrirait sa propre branche et
    sa propre PR à côté, et #50, devenue « lot », ne serait plus jamais servie."""
    for number in chain:
        if is_feature(reader.issue(number)):
            return number, False
    return chain[-1], True


def est_carte(reader, number, chain):
    """Une issue qui a des sous-issues est un LOT — sauf la racine d'une mini-feature,
    qui reste la carte de sa feature (ses sous-issues sont servies après elle)."""
    feature, mini = feature_of(reader, chain)
    if mini and number == feature:
        return True
    return not is_lot(reader.issue(number))


def has_label(issue, name):
    labels = issue.get("labels")
    if not isinstance(labels, list):
        raise LookupFailure("labels illisibles sur #%s" % issue.get("number"), 3)
    return any(isinstance(label, dict) and label.get("name") == name for label in labels)


def cmd_of(repo, number):
    reader = Reader(repo)
    card = reader.issue(number)
    if is_feature(card):
        raise LookupFailure("#%s est une issue de type %s : une feature n'est jamais une carte" % (number, FEATURE_TYPE), 3)
    chain = reader.chain(number)
    if not est_carte(reader, number, chain):
        raise LookupFailure("#%s a des sous-issues : c'est un lot, pas une carte" % number, 3)
    feature, mini = feature_of(reader, chain)
    print(json.dumps({"card": number, "feature": feature, "mini": mini, "chain": chain,
                      "card_issue": card, "feature_issue": reader.issue(feature)}, ensure_ascii=False))
    return 0


def cmd_rank(repo):
    data = json.load(sys.stdin)
    if not isinstance(data, dict) or not isinstance(data.get("open"), list) or not isinstance(data.get("candidates"), list):
        raise LookupFailure("entrée de rank illisible ({open: [...], candidates: [...]})", 3)
    prio, busy = os.environ.get("PRIO"), os.environ.get("BUSY")
    if not prio or not busy:
        raise LookupFailure("PRIO et BUSY (noms de label) doivent être dans l'environnement : l'appelant les résout par label_get", 3)
    milestone = os.environ.get("MILESTONE", "")
    reader = Reader(repo, data["open"])
    rows, lots, features, jalons = [], [], [], []
    for number in data["candidates"]:
        if type(number) is not int:
            raise LookupFailure("candidate illisible : %r" % (number,), 3)
        card = reader.issue(number)
        # La sélection a déjà écarté les Features ; on le refait ici parce que
        # c'est CE lecteur qui sait ce qu'est une Feature, et qu'un appelant
        # qui l'oublierait ferait naître une branche feature/<F> pour F.
        if is_feature(card):
            features.append(number)
            continue
        chain = reader.chain(number)
        if not est_carte(reader, number, chain):
            lots.append(number)
            continue
        feature, mini = feature_of(reader, chain)
        # LE JALON EST HÉRITÉ DE LA FEATURE quand la carte n'en a pas (M10) :
        # une carte née sous une feature « v2.0 » appartient à v2.0, même si
        # personne n'a pensé à l'étiqueter. Vide = aucun filtre.
        if milestone:
            m = card.get("milestone") or (reader.issue(feature).get("milestone") if not mini else None)
            if m and m.get("title") != milestone:
                jalons.append(number)
                continue
        # Le chemin va du SOMMET vers la carte : la position du lot dans la
        # feature, puis celle de la carte dans le lot. Une mini-feature n'a pas
        # de chemin, son numéro suffit.
        path = []
        above = chain[1:]
        for child, parent in zip(chain, above):
            path.append(reader.position(parent, child))
        path.reverse()
        rows.append({"number": number, "feature": feature, "mini": mini, "path": path,
                     "busy": has_label(card, busy), "prio": has_label(card, prio),
                     "prio_feature": has_label(reader.issue(feature), prio)})
    if features:
        print("gh-feature: %d feature(s) — l'unité de livraison, jamais une carte : %s" % (len(features), ", ".join("#%d" % n for n in features)), file=sys.stderr)
    if lots:
        print("gh-feature: %d lot(s) — un fil de cartes, pas une carte : %s" % (len(lots), ", ".join("#%d" % n for n in lots)), file=sys.stderr)
    if jalons:
        print("gh-feature: %d carte(s) d'un autre jalon que « %s » (le sien, ou celui de sa feature) : %s" % (len(jalons), milestone, ", ".join("#%d" % n for n in jalons)), file=sys.stderr)
    rows.sort(key=lambda r: (not r["busy"], not r["prio"], not r["prio_feature"], r["feature"], r["path"], r["number"]))
    print(json.dumps(rows, ensure_ascii=False))
    return 0


def main():
    if len(sys.argv) < 3:
        raise LookupFailure("usage : gh-feature.py of <repo> <carte> | rank <repo>", 3)
    mode, repo = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", repo):
        raise LookupFailure("dépôt invalide", 3)
    if mode == "of":
        if len(sys.argv) != 4 or not sys.argv[3].isdigit():
            raise LookupFailure("usage : gh-feature.py of <repo> <carte>", 3)
        return cmd_of(repo, int(sys.argv[3]))
    if mode == "rank":
        return cmd_rank(repo)
    raise LookupFailure("mode inconnu : %s" % mode, 3)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LookupFailure as error:
        print("gh-feature: " + str(error), file=sys.stderr)
        sys.exit(error.code)
    except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
        print("gh-feature: données illisibles (%s)" % error, file=sys.stderr)
        sys.exit(4)
