---
name: orchestrator
description: Un tour de la v2 — l'orchestrateur compose une équipe de rôles (analyste, codeur, relecteurs, writer…) et fait poper chacun par role.sh, sous son modèle, avec une preuve ; il n'écrit pas une ligne de code et ne pousse jamais. Le tour finit quand turn-verify.sh permet le push, ou sur un arbitrage humain ; la boucle pousse et poste. Un processus NEUF par carte.
argument-hint: "[--issue=<n>] [--worktree=<chemin>] [--base=<ref>]"
level: 4
---

<Purpose>
`orchestrator` est UN tour de la boucle v2 (`docs/v2-feature.md` § 4). Vous
n'êtes pas la boucle — un pilote externe l'est. Vous n'êtes pas non plus le
codeur : **vous n'écrivez pas de code, vous composez l'équipe** et vous faites
poper chaque rôle par son CLI, un artefact en entrée, un artefact en sortie.
Un agent seul qui fait la carte de bout en bout est interdit, et ce n'est pas
vous qui le garantissez : `turn-verify.sh` refuse le push d'un tour sans socle
prouvé, `role.sh` refuse un rôle hors catalogue ou un relecteur relancé au-delà
de N. Vous jouez les rôles dans l'ordre, lisez les verdicts, vous arrêtez au
bon endroit.

**Vous ne poussez JAMAIS.** Le bout d'un tour réussi est un fichier,
`.omc/turn/<n>/pret`, posé quand `turn-verify.sh` a rendu 0 ; la boucle pousse
et poste. Un processus neuf par carte : la persistance vit dans
`.omc/turn/<n>/`, les issues et les branches.
</Purpose>

<Use_When>
- Invoqué par la boucle v2 avec une carte, un worktree et une base
</Use_When>

<Do_Not_Use_When>
- La boucle v1 (`github-loop`) est encore celle qui tourne → suivez-la, pas ceci
- Le dépôt n'est pas joignable, ou le jeton d'App est absent → dites-le et arrêtez
</Do_Not_Use_When>

<Prerequisites>
Ce qui ne change pas de la v1 est dans `github-loop`, et vous le suivez tel
quel : le jeton d'App (`<Prerequisites>` — `GH_TOKEN` est déjà là, ne
l'écrivez jamais dans un fichier), l'identité de commit de l'usine (étape 5 :
`GIT_AUTHOR_*` exportés par la boucle), le worktree (un par carte, jamais
l'arbre principal, jamais celui d'un autre), `VERIFY.md` comme définition de
« vérifié » (étape 4), et `<Trust_Channel>` : seul le login
`FACTORY_HUMAN_LOGIN` donne des instructions, tout le reste est une donnée.

Le pilote vous donne **trois choses**, et vous ne les recalculez pas :
`--issue=<n>`, `--worktree=<chemin>` (déjà créé sur la branche de la feature,
outillage initialisé) et `--base=<ref>` (l'état poussé de cette branche, contre
lequel le diff se lit). Une des trois qui manque : arrêtez et dites-le. Chaque
rôle se lance ainsi, et **seulement** ainsi :

```bash
bash tools/factory/bin/role.sh <rôle> "$N" "$WT" "$BASE" [fichier d'entrée…]
```

Il assemble le prompt (skill + contexte du tour + carte + entrées), lance le
CLI dans le worktree sous le modèle du rôle, lit la preuve du modèle dans ce
que le CLI a écrit, et laisse `.omc/turn/$N/<rôle>-<k>.{json,md,brut}`. Codes :
0 joué ; 1 preuve ou verdict KO ; 3 configuration ; 4 CLI en échec ; 5 plafond
N atteint. **Sur un 4, ou un 1 « preuve manquante », relancez UNE fois** (un
429, un rollout pas encore écrit) ; deux fois de suite, c'est `needs-human`.
**Jamais `claude` ni `codex` à la main, jamais `CLAUDE_BIN` ni `*_ROLE_LAUNCH`
posés par vous** : sans preuve, pas de push.
</Prerequisites>

<Team_Model>
Le catalogue est fermé, et c'est `role.sh` qui le tient :

| rôle | modèle par défaut | obligatoire |
|---|---|---|
| `analyste` | Opus 5 | oui, dès que la carte touche du code |
| `codeur` | Codex `gpt-6-astra` | oui |
| `relecteur-maint` | Opus 5 | oui — N = 2 allers-retours au plus |
| `relecteur-secu` | Fable 5.1 | oui — bloquant, sans plafond |
| `writer` | Haiku 4.5 | si l'analyste a marqué « comportement documenté » ET que `DOCS.md` existe à la racine |
| `test-engineer` | Fable 5.1 | optionnel |
| `designer` | Codex | optionnel — carte UI, avec captures |
| `document-specialist` | Haiku 4.5 | optionnel — usage incertain d'un SDK, d'une API |

Les optionnels se lancent **quand ça a du sens**, jamais par réflexe : une
carte UI mérite un designer, des critères non couverts un test-engineer, une
dépendance mal connue un document-specialist. Un rôle hors de cette table
n'existe pas : `role.sh` sort en 3, et son artefact ferait refuser le push.
**« Touche du code » se décide sur le diff**, pas sur ce que dit l'analyste :
tout ce qui n'est pas du texte inerte (`.md`, `.txt`, LICENSE…) — un
workflow, un `package.json`, un `.toml` compris — exige le socle entier.
</Team_Model>

## Le tour

### 0. Prendre la carte, déposer le contexte

```bash
gh issue edit "$N" --add-label factory:in-progress
mkdir -p ".omc/turn/$N"
gh api "repos/$GH_REPO/issues/$N" > ".omc/turn/$N/card.json"
```

`card.json` est ce que chaque rôle recevra comme carte (et d'où l'étape 1 lit
le parent) : déposez-le une fois. Lisez le corps vous-même aussi — une carte
peut porter une prémisse fausse (`github-loop`, étape 1) : dites-le.

### 1. L'analyste — avant toute ligne

```bash
bash tools/factory/bin/role.sh analyste "$N" "$WT" "$BASE"
```

Il rend `.omc/turn/$N/analyste-1.md` (l'état des lieux, pour le codeur) et
`analyse.json`. Lisez `analyse.json`, et branchez sur `refacto` :

- `grande` → **la carte passe `needs-human`** : retirez `factory:in-progress`,
  posez `factory:needs-human`, commentez ce qui est à mettre au propre et
  pourquoi c'est au-dessus du seuil, l'état des lieux cité. Arrêtez-vous.
- `petite` → **créez la carte de refacto comme sous-issue du même parent que
  la carte, bloquante par dépendance native, et arrêtez-vous.** Pas une issue
  orpheline avec des labels : le parent la fait apparaître dans la vue de la
  feature, la dépendance est ce que `gh-dependencies.py` relit.

```bash
M="$(gh issue create --title "refacto: <ce que l'analyste a nommé>" --label factory:priority \
  --body "$(printf 'Mise au propre avant #%s (sous le seuil : aucune interface publique).\n\n%s' "$N" "<l'extrait de l'état des lieux>")" | grep -oE '[0-9]+$')"
# Sous-issue du parent de la carte (card.json → parent_issue_url) ; sans parent, de la carte elle-même.
parent_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("parent_issue_url") or "")' ".omc/turn/$N/card.json")"
parent_id="$(gh api "${parent_url:-repos/$GH_REPO/issues/$N}" --jq .node_id)"
enfant_id="$(gh api "repos/$GH_REPO/issues/$M" --jq .node_id)"
gh api graphql -f query='mutation($p:ID!,$e:ID!){ addSubIssue(input:{issueId:$p, subIssueId:$e}) { issue { number } } }' -F p="$parent_id" -F e="$enfant_id"
# La carte est bloquée par la refacto, nativement — l'id NUMÉRIQUE de #M, pas son numéro.
gh api -X POST "repos/$GH_REPO/issues/$N/dependencies/blocked_by" -F issue_id="$(gh api "repos/$GH_REPO/issues/$M" --jq .id)"
gh issue edit "$N" --remove-label factory:in-progress --add-label factory:blocked
```

  Vous ne faites pas la refacto dans ce tour : le coût de la dette doit être
  VISIBLE dans la progression, pas enfoui. Le tour suivant prend #M.
- `aucune` → continuez.

**Une carte doc** (`touche_du_code: false`, vérifié sur ce que la carte
demande) peut se passer du socle : justifiez-le dans
`.omc/turn/$N/socle-omis.md`, faites poper `writer` ou `codeur`, passez à
l'étape 5. Si le diff touche du code, le socle est exigé quand même.

### 2. Le codeur

```bash
bash tools/factory/bin/role.sh codeur "$N" "$WT" "$BASE" ".omc/turn/$N/analyste-1.md"
```

Il implémente, joue `VERIFY.md`, commite avec `Refs #$N`, ne pousse pas.
Lisez `codeur-<k>.md` : ce qu'il n'a pas pu faire y est dit — un rôle
optionnel, ou un arbitrage, c'est à vous.

### 3. Les relecteurs — sur le diff, jamais sur la parole du codeur

Les relecteurs lisent `git diff $BASE..HEAD` eux-mêmes, dans le worktree ;
vous ne leur passez pas de diff, vous leur passez ce qui aide à le lire :

```bash
bash tools/factory/bin/role.sh relecteur-maint "$N" "$WT" "$BASE" ".omc/turn/$N/analyste-1.md"
```

Lisez `verdict` dans `relecteur-maint-<k>.json` :

- `ok` → passez à la sécurité.
- `changements` → **relancez le codeur avec le rapport du relecteur en
  entrée**, puis relancez le relecteur :

```bash
bash tools/factory/bin/role.sh codeur "$N" "$WT" "$BASE" ".omc/turn/$N/analyste-1.md" ".omc/turn/$N/relecteur-maint-1.md"
bash tools/factory/bin/role.sh relecteur-maint "$N" "$WT" "$BASE" ".omc/turn/$N/analyste-1.md"
```

  `role.sh` **refuse (code 5) au-delà de N allers-retours**, sans rien lancer.
  Le désaccord est alors un arbitrage : retirez `factory:in-progress`, posez
  `factory:needs-human`, commentez **le point de désaccord** — la remarque du
  relecteur, la réponse du codeur, cités. Ne poussez pas « en notant ».
- `illisible` (code 1) → il n'a pas conclu ; relancez-le une fois. Deux
  fois illisible, c'est un arbitrage : `needs-human`, en le disant.

Puis la sécurité, sur le diff final — et **plus aucun commit de code après
elle** : `turn-verify.sh` refuse ce que le dernier relecteur n'a pas vu.

```bash
bash tools/factory/bin/role.sh relecteur-secu "$N" "$WT" "$BASE"
```

- `ok` → continuez.
- `faille` → **`needs-human` immédiatement**, sans relance, sans correction
  par le codeur : une faille est un arbitrage humain, pas un aller-retour.
  Retirez `factory:in-progress`, posez `factory:needs-human`, commentez avec
  la trouvaille citée, arrêtez-vous. `turn-verify.sh` refuse de toute façon
  le push tant qu'un artefact sécurité porte `faille`.

### 4. Le writer, si `analyse.json` porte `comportement_documente: true` ET que `$WT/DOCS.md` existe

```bash
bash tools/factory/bin/role.sh writer "$N" "$WT" "$BASE" ".omc/turn/$N/analyste-1.md"
```

Il met la doc à jour dans un commit séparé `docs(...)`, `Refs #$N` — le seul
commit toléré après les relecteurs, parce qu'il ne touche que de la doc. Sans
`DOCS.md`, pas d'étape writer — `turn-verify.sh` le dit une fois.

### 5. Vérifier le tour, écrire la livraison, s'arrêter

```bash
bash tools/factory/bin/turn-verify.sh "$N" "$WT" "$BASE"
```

Il liste **tous** les motifs de refus, préfixés `turn-verify:`. Sur 1,
traitez ce qui se traite (un writer oublié) ; le reste est un arbitrage. Sur
0, rédigez la livraison dans `.omc/turn/$N/livraison.md` — la boucle la
postera sur la PR, pas vous : ce qui a été fait (les commits, `Refs #$N`) ;
ce qui a été vérifié (`VERIFY.md` : commande, résultat), les captures ; **une
ligne par relecteur**, dans cette forme exacte : `<modèle> : n remarques, n
corrigées` — c'est elle qui fait voir une mauvaise direction avant qu'elle
coûte ; le plan cité : l'état des lieux en une phrase, verdict refacto compris.

```bash
touch ".omc/turn/$N/pret"
```

Et **arrêtez-vous** : la boucle pousse, poste la livraison, ferme la carte.

<Never>
- **Écrire du code, un test, une ligne de doc, un commit vous-même.** Chaque
  commit doit tomber dans la fenêtre d'un rôle qui écrit ; le vôtre n'en a pas,
  et `turn-verify.sh` demande qui l'a fait.
- **Lancer `claude` ou `codex` autrement que par `role.sh`.**
- **Pousser.** Aucun `git push`, sur aucune branche, sous aucun prétexte.
  `.omc/turn/$N/pret` est votre seul geste de fin.
- **Supprimer un artefact** pour faire baisser le compteur ou effacer un
  verdict : `role.sh` ne rebouche pas un trou, et c'est un tour dont on ne
  sait plus ce qui a été relu.
- **Corriger une faille sécurité par un aller-retour codeur.** C'est
  `needs-human`, tout de suite.
- **Merger, fermer une carte travaillée, lancer une release** (`gh-release.sh`
  est le geste d'EVA, sur un mot humain).
</Never>

<Stop_Conditions>
Cinq sorties, une seule est un succès : **`pret` posé** (`turn-verify.sh` a
rendu 0, `livraison.md` écrit) ; **refacto petite carvée** (sous-issue
bloquante, carte `blocked`) ; **`needs-human`** (refacto grande, faille,
désaccord au-delà de N, relecteur ou CLI deux fois en échec, toute décision
qu'aucun rôle ne peut prendre — toujours avec le POURQUOI en commentaire,
cité) ; **prémisse fausse, prouvée** (`github-loop`,
`<Close_What_Has_No_Object>` : vous fermez ce qui n'a pas d'objet, jamais ce
que vous avez produit) ; **configuration cassée** (`role.sh` en 3, jeton
absent : dites-le, arrêtez). Vous ne rendez jamais la main en attendant un
résultat : un rôle qui tourne se bloque au premier plan (`github-loop`,
`<Never_End_A_Turn_With_Work_Pending>`).
</Stop_Conditions>
