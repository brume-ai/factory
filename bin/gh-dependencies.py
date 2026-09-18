#!/usr/bin/env python3
"""Shared read-only dependency gate. Never treat a failed lookup as no blockers."""
import json
import os
import re
import subprocess
import sys
import tempfile


class LookupFailure(Exception):
    # `status` : le code HTTP quand l'échec vient de l'API — l'appelant qui
    # tolère un 404 (une référence morte dans un message de commit) le lit ici,
    # jamais dans le texte du message.
    def __init__(self, message, code=4, status=None):
        super().__init__(message)
        self.code = code
        self.status = status


def request(path):
    with tempfile.TemporaryDirectory(prefix="factory-dependencies-") as directory:
        body, headers = directory + "/body", directory + "/headers"
        result = subprocess.run([
            "curl", "-sS", "--retry", "3", "--retry-delay", "2",
            "--retry-connrefused", "--connect-timeout", "10", "--max-time", "60",
            "-o", body, "-D", headers, "-w", "%{http_code}",
            "-H", "Authorization: Bearer " + os.environ["FACTORY_TOKEN"],
            "-H", "Accept: application/vnd.github+json",
            "https://api.github.com/" + path,
        ], capture_output=True, text=True)
        if result.returncode:
            raise LookupFailure("transport KO sur /" + path)
        with open(body) as source:
            raw = source.read()
        status = result.stdout
        if status != "200":
            transient = status in ("000", "429") or status.startswith("5") or (
                status == "403" and "rate limit" in raw.lower())
            raise LookupFailure("HTTP %s sur /%s" % (status, path), 4 if transient else 3, status)
        try:
            value = json.loads(raw)
        except ValueError:
            raise LookupFailure("réponse illisible sur /" + path)
        with open(headers) as source:
            links = source.read()
        next_links = re.findall(r'<([^>]+)>;\s*rel="next"', links, re.I)
        next_path = ""
        if next_links:
            prefix = "https://api.github.com/"
            if len(next_links) != 1 or not next_links[0].startswith(prefix):
                raise LookupFailure("pagination inattendue sur /" + path)
            next_path = next_links[0][len(prefix):]
        return value, next_path


def issue_state(issue):
    if not isinstance(issue, dict) or "pull_request" in issue:
        raise LookupFailure("le bloqueur doit être une issue")
    labels = issue.get("labels")
    if issue.get("state") not in ("open", "closed") or not isinstance(labels, list):
        raise LookupFailure("état ou labels du bloqueur illisibles")
    if any(not isinstance(label, dict) or not isinstance(label.get("name"), str) for label in labels):
        raise LookupFailure("labels du bloqueur illisibles")
    return {label["name"] for label in labels}


def dependencies(repo, number, body, numbers_only=False, natif=False):
    """`natif` : les relations natives SEULEMENT, jamais le repli textuel du corps.
    La base d'une PILE (feature-up.sh) ne vient que d'une dépendance déclarée :
    un « Dépend de #12 » dans le corps d'une feature est une phrase, pas une
    relation, et en faire une base de branche empilait une feature sur une
    autre sans que GitHub le sache — donc sans retarget au merge."""
    path = "repos/%s/issues/%s/dependencies/blocked_by?per_page=100" % (repo, number)
    prefix = path.split("?", 1)[0] + "?"
    seen, blockers = set(), []
    while path:
        if path in seen or len(seen) >= 100 or not path.startswith(prefix):
            raise LookupFailure("pagination des dépendances incomplète ou cyclique")
        seen.add(path)
        page, path = request(path)
        if not isinstance(page, list):
            raise LookupFailure("la liste des dépendances est illisible")
        blockers.extend(page)
    source = "native"
    if not blockers and not natif:
        source = "body"
        numbers = set()
        for match in re.finditer(r"(?:Bloqu[ée]e? par|Blocked by|D[ée]pend de)\s*:?\s*((?:#\d+[ \t,;/et]*)+)", body or "", re.I):
            numbers.update(int(n) for n in re.findall(r"#(\d+)", match[1]))
        for dependency in sorted(numbers):
            if numbers_only:
                blockers.append({"number": dependency})
                continue
            blocker, _ = request("repos/%s/issues/%s" % (repo, dependency))
            # The requested URL identifies a historical body-only dependency.
            if isinstance(blocker, dict):
                blocker = dict(blocker, number=dependency)
            blockers.append(blocker)
    for blocker in blockers:
        if not isinstance(blocker, dict):
            raise LookupFailure("bloqueur illisible")
        if source == "native":
            issue_state(blocker)
        if numbers_only:
            if source == "native" and not (blocker.get("repository_url") or blocker.get("url")):
                raise LookupFailure("dépôt du bloqueur illisible pour la pile")
            repository_url = blocker.get("repository_url", "https://api.github.com/repos/" + repo)
            issue_url = blocker.get("url", "https://api.github.com/repos/%s/issues/%s" % (repo, blocker.get("number")))
            if (repository_url.lower() != ("https://api.github.com/repos/" + repo).lower() or
                    issue_url.lower() != ("https://api.github.com/repos/%s/issues/%s" % (repo, blocker.get("number"))).lower()):
                raise LookupFailure("une pile ne peut pas utiliser un bloqueur externe", 3)
        else:
            issue_state(blocker)
        if type(blocker.get("number")) is not int or blocker["number"] <= 0:
            raise LookupFailure("numéro du bloqueur illisible")
    return blockers, source


def main():
    # Trois modes, tous nourris par l'issue sur stdin : `check` (la sélection :
    # 0 prête, 1 bloquée), `inspect` (gh-unblock : le JSON des bloqueurs et leur
    # source), `numbers` (feature-up : les numéros, pour la base d'une pile ;
    # avec `--natif`, sans le repli textuel). Le repli textuel (« Bloquée par
    # #n » dans le corps) reste pour la SÉLECTION des cartes historiques.
    # `resume` et `maintenance` (la reprise d'un worktree, l'entretien d'une PR
    # de carte) sont partis avec la v1 : plus d'appelant, plus de mode.
    mode, repo, number = sys.argv[1:4]
    natif = sys.argv[4:] == ["--natif"]
    if mode not in ("check", "inspect", "numbers") or (sys.argv[4:] and not natif) or (natif and mode != "numbers"):
        raise LookupFailure("mode inconnu (check | inspect | numbers [--natif])", 3)
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", repo) or not number.isdigit():
        raise LookupFailure("dépôt ou numéro invalide", 3)
    issue = json.load(sys.stdin)
    if not isinstance(issue, dict):
        raise LookupFailure("issue illisible")
    blockers, source = dependencies(repo, number, issue.get("body"), mode == "numbers", natif)
    if mode == "numbers":
        print(json.dumps([blocker["number"] for blocker in blockers]))
        return 0
    staged = os.environ["FACTORY_STAGED_LABEL"]
    ready = all(blocker["state"] == "closed" or staged in issue_state(blocker) for blocker in blockers)
    if mode == "inspect":
        print(json.dumps({"ready": ready, "source": source, "blockers": blockers}))
        return 0
    if not ready:
        print("gh-dependencies: #%s bloquée par des dépendances %s non intégrées" % (number, source), file=sys.stderr)
    return 0 if ready else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LookupFailure as error:
        print("gh-dependencies: " + str(error) + " — aucune admission", file=sys.stderr)
        sys.exit(error.code)
    except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
        print("gh-dependencies: données illisibles — aucune admission (%s)" % error, file=sys.stderr)
        sys.exit(4)
