# La v2 en exploitation : la feature, le tour, la release

Le document de référence côté opérations. [`v2-feature.md`](v2-feature.md)
est le récit de la décision (le 18 septembre 2026, pourquoi la v1 a été
remplacée) ; celui-ci dit **ce que le code livré fait**, script par script, et
ce qu'un humain a encore à faire. Chaque affirmation a été relue dans `bin/`,
`factory.mk`, `skill/` et `nix/` — quand un écart apparaîtra, c'est le code qui
a raison et cette page qui est à corriger.

```
feature (issue Feature) ─ cartes (sous-issues) ─ commits sur feature/<F> ─ PR relue par lot
        → staging (EVA merge, sur approve ou ordre)  → main (EVA release, sur ordre)
```

Ce qui n'existe plus, pour qu'on ne le cherche pas : la PR de carte (`card/<n>`)
et son merge automatique (`gh-stage-pr.sh`), le mode entretien d'une PR, la
reprise d'un worktree (`wt-resume.sh`), `MAIN=codex`, les labels de cycle
`factory:delivered` / `factory:staged` sur les **cartes**, la protection de
branche comme garantie, `gh-stack.sh` (la pile se calcule dans
`feature-up.sh`, depuis les dépendances de la feature).

## Le cycle d'une carte

Une carte est une issue GitHub **feuille** : une sous-issue d'une feature ou
d'un lot, ou une issue orpheline. Une issue de type `Feature` n'est jamais une
carte ; une issue qui a des sous-issues est un **lot**, jamais une carte — sauf
la racine d'une mini-feature (plus bas). `gh-feature.py` est le seul lecteur
de cette règle, et `gh-next-issue.sh` la lui délègue.

**La file est opt-out.** Une issue ouverte *est* du travail. Ce qui l'écarte,
et chaque cas est dit sur stderr du sondage : le type `Feature` ; un label de
mise de côté — `factory:epic` (un fil), `factory:needs-human` (une décision
attend), `factory:blocked` (retiré par `gh-unblock.sh` quand le bloqueur
tombe) ; une dépendance native non satisfaite (`gh-dependencies.py` : un
bloqueur est satisfait s'il est **fermé** ou s'il porte `factory:staged`, le
label de feature) ; un jalon **autre** que `FACTORY_MILESTONE` — hérité de la
feature quand la carte n'en a pas ; un lot.

**L'ordre** (`gh-feature.py rank`) : la carte déjà prise d'abord (le tour
interrompu, son répertoire de tour l'attend), puis `factory:priority` sur la
carte, puis sur sa feature, puis la feature au numéro le plus bas (une feature
se finit avant que la suivante commence — c'est ce qui rend la relecture par
lot possible), puis la position dans les sous-issues de chaque parent du haut
vers le bas (l'ordre que l'humain réordonne à la souris), puis le numéro.

**Les labels que l'usine pose, et qui les pose.** La règle est : **tous les
noms viennent de `label_get`** (`lib.sh`, un défaut par label, surchargé par
`factory.conf`) — celui qui pose (`card-state.sh`, `gh-pr-attention.sh`,
`gh-release.sh`, `eva-merge.sh`), celui qui lit (`gh-next-issue.sh`,
`gh-dependencies.py`, `eva-watch.sh`), et le triage Python, qui les reçoit
résolus de `factory.mk`. Aucun skill ne tape un nom de label : l'orchestrateur
passe par `card-state.sh`, EVA par `card-state.sh decided` ; sinon un
consommateur qui en renomme un aurait une sélection qui parle un mot et un
poseur qui en écrit un autre.

| Ce qui arrive | Label | Posé par | Retiré par |
|---|---|---|---|
| l'orchestrateur prend la carte | `factory:in-progress` | `card-state.sh busy` (étape 0 du skill) | `card-state.sh unbusy` (refacto carvée), `needs-human` |
| une carte doit passer devant | `factory:priority` | `card-state.sh priority` (la refacto carvée par l'analyste), `gh-pr-attention.sh` (remarque, CI rouge), `gh-security-triage.py` | personne — un humain |
| une décision attend | `factory:needs-human` | `card-state.sh needs-human "<raison>"` : retire `busy`, pose le label, commente la raison, **puis** pose le marqueur `.omc/turn/<n>/needs-human` — dans cet ordre, un label refusé ne remet pas le tour à zéro | EVA, une fois la décision écrite (`<!-- factory:decision -->`), sans jamais fermer la carte |
| un bloqueur est tombé | `factory:blocked` | un humain | `gh-unblock.sh`, à chaque tour |

`factory:delivered` est encore semé par `gh-seed-labels.sh` et lu par le
triage de sécurité (une spec gelée), mais **plus posé sur une carte**.

**Qui pose `needs-human`** : l'orchestrateur (refacto au-dessus du seuil,
désaccord de relecture au-delà de N, faille de sécurité, relecteur deux fois
illisible), `feature-up.sh` (carte sous une Feature fermée, worktree sur une
autre branche, branche locale avec des commits jamais poussés, PR refusée par
GitHub en 422), `deliver.sh` (PR de la feature mergée ou fermée entre
l'admission et la livraison — le commit est **déjà sur la branche**, la raison
dit de fermer la carte « not planned » plutôt que de la réadmettre, parce qu'une
réadmission repart d'un tour vide et referait le travail par-dessus),
`gh-pr-attention.sh` (une remarque qu'on ne sait pas rattacher).

**La fermeture, à la livraison.** Quand `turn-verify.sh` a rendu 0 et que la
boucle a poussé, `deliver.sh` ferme la carte (`state_reason: completed`) avec
« Livrée dans `<sha7>` sur `feature/<F>` (PR #`<pr>`) », marqué
`<!-- factory:livree #n -->`. La barre de progression de la feature avance
pendant le travail. La release ne ferme **jamais** une carte : une carte encore
ouverte dans la plage d'une release est signalée sur la liste et commentée
(« encore OUVERTE — la release ne la ferme pas »), c'est tout.

**La mini-feature.** Une carte dont la chaîne des parents ne contient aucune
issue `Feature` est sa propre feature — un hotfix, une demande ponctuelle —,
même flux, pas de second chemin vers la production. La feature est alors la
**racine** de la chaîne, et cette racine reste une carte servable même quand
elle a des sous-issues (une remarque transformée par `gh-pr-attention.sh`, une
refacto carvée) : ses sous-issues sont des cartes sur `feature/<racine>`,
servies après elle. Sans cette règle, la première remarque sur un hotfix en
faisait un lot jamais servi.

## Le cycle d'une feature

**Une feature = une issue de type `Feature` = une branche `feature/<F>` = un
worktree `.worktrees/feature-<F>` = une PR vers `staging`.** Les types d'issue
sont actifs sur les organisations en plan gratuit (vérifié le 18 septembre
2026 sur `Paris-Showroom`) ; le fallback label n'a pas été écrit.

**La naissance, par la boucle** (`feature-up.sh`, à l'admission de la première
carte) : la branche depuis `origin/staging` ; le worktree, par le crochet
`worktree-up feature-<F> <base>` du consommateur s'il existe (il doit laisser
le worktree sur `feature/<F>`, vérifié) ; le sous-module de l'usine
initialisé ; un commit vide `chore: ouvre feature/<F>` signé par la boucle —
GitHub refuse une PR sans commit entre la base et la tête, et ce commit est
avant la base du premier tour, donc hors de tout diff relu ; la PR en
**brouillon**, titrée du titre de la feature, corps `Feature #F`. Tout est
idempotent : rejoué après un tour mort, il retrouve ce qui existe et ne
recrée rien ; un worktree existant n'est jamais réinitialisé (du travail non
poussé y attend peut-être), il avance en `ff-only` s'il est propre et en
retard.

**La pile.** Si la feature F dépend nativement d'une feature G **ouverte**,
dont la branche `feature/<G>` existe sur origin et qui ne porte pas
`factory:staged`, F part de `origin/feature/<G>` et sa PR vise `feature/<G>` ;
GitHub retarge la PR sur `staging` quand la branche de G disparaît. Plusieurs
G : le plus haut numéro, dit. Rien d'autre ne fait une pile — pas « touche les
mêmes fichiers », qui ne se voit qu'après, et **pas un « Dépend de #G » dans
le corps** (`gh-dependencies.py numbers --natif`) : une phrase n'est pas une
relation, GitHub ne retargerait pas la PR au merge de G. Le repli textuel du
corps (« Bloquée par #n ») ne sert plus qu'à la **sélection** des cartes
historiques.

**La relecture, par lot, au fil de l'eau.** À chaque carte livrée, la boucle
pousse, poste sur la PR un commentaire de livraison (la prose de
l'orchestrateur, suivie d'un bloc **généré depuis les artefacts** : une ligne
par rôle prouvé — modèle, passes, dernier verdict —, la ligne refacto de
l'analyste, les captures inlinées), passe la PR « prête » si elle était en
brouillon, et ajoute `- #n — titre (sha)` au corps de la PR. EVA ping « PR
prête à relire » (plus bas). L'humain relit un lot de commits, pas une feature
de cinquante-huit d'un coup.

**L'intégration, par EVA seule** (`eva-merge.sh <pr>`), sur une preuve d'ordre
humain, l'une des deux :

- l'*approve* GitHub de `FACTORY_HUMAN_LOGIN` dont le `commit_id` est la tête
  **courante** de la PR — une approbation sur une tête antérieure est périmée
  (une remarque devenue carte, livrée après l'approve, est un état que l'humain
  n'a pas vu), et un « changes requested » postérieur annule l'approve
  d'avant ;
- `--ordre "slack:<ts>" --tete <sha>` : le mot de l'humain en Slack, et la
  tête qu'il a vue ; si la PR a bougé depuis, refus. La référence est écrite
  dans le commit de merge et dans deux commentaires — c'est une **trace**, pas
  une vérification : le script ne lit pas Slack, c'est l'allowlist Slack
  d'EVA qui garantit qui parle.

Toutes les gardes sont relues et tous les motifs sont dits d'un coup : la PR
ouverte et hors brouillon ; la tête `feature/<n>` **du dépôt lui-même** (la
tête d'une PR de fork porte le nom de branche chez le fork) ; la base
`staging` ou la feature du dessous d'une pile ; ni la PR ni sa feature ne
portent `factory:needs-human` ; `mergeable` strictement `true` (`null` = GitHub
n'a pas fini de calculer, trois relectures espacées de
`FACTORY_MERGEABLE_WAIT` secondes) ; la CI verte en **liste blanche**
(`success`, `neutral`, `skipped` ; `cancelled`, `timed_out`, `action_required`,
`stale` sont rouges ; **aucun contrôle = refus** ; la liste est lue en entier,
page après page). **Merge commit, jamais squash** : la release relit les
`Refs #n` des commits de carte. Puis, **seulement quand la base est
`staging`**, `factory:staged` est posé sur la feature — « intégrée, pas
sortie » se lit sur la feature, et c'est la seule preuve qu'EVA a mergé sur un
ordre humain. Mergée dans `feature/<G>` (une couche de pile), la feature ne
reçoit rien : elle sortira avec G. Déjà mergée : rien à refaire, dit.

**Une carte après le merge.** La feature reste ouverte jusqu'à la release ;
une carte qui lui arrive entre-temps la **rouvre** (`feature-up.sh`) : un
commit vide `chore: rouvre feature/<F>` (sans lui GitHub refuserait la PR,
tout étant déjà mergé), une PR neuve. Une carte sous une feature **fermée**
est refusée (`needs-human`) : la feature est sortie, rouvrir sa branche en
silence ferait livrer du code sous une feature que tout le monde croit finie.

**La fermeture, à la release** (`gh-release.sh`, plus bas) : une feature est
fermée quand elle est **complète** — `sub_issues_summary.completed == total`
**et** aucune carte de la plage encore ouverte (le compte de GitHub ne voit que
les enfants directs : un lot fermé au-dessus d'une carte ouverte passerait) —
et qu'elle porte `factory:staged`. Elle perd le label et reçoit la trace de la
version. **Une mini-feature n'est complète que si sa racine est fermée** — la
racine est la carte du hotfix, pas un chapeau : un hotfix en `needs-human`
dont la remarque livrée dessous compte 1/1 sortait « complet » avant cette
règle ; fermée à la livraison, elle reçoit la trace et perd le label, rien
d'autre. **La feature permanente des alertes** (`FACTORY_SECURITY_FEATURE`)
est hors de ces règles : ses cartes sorties sont commentées, son label retiré,
elle n'est ni fermée ni bloquante (plus bas, « La release »).

**Le nettoyage** (`wt-cleanup.sh`, à chaque tour) : le worktree `feature-<F>`
est détruit quand la PR de la feature est mergée ou fermée — jamais une PR
ouverte, jamais un worktree qui ne s'appelle pas `feature-<F>`.

## Les branches, et qui y écrit

| Branche | Rôle | Qui y écrit | Par quoi |
|---|---|---|---|
| `feature/<F>` | le travail d'une feature ; la base de la PR d'une feature empilée dessus (`feature/<G>` → `feature/<F>`, retargée sur `staging` par GitHub quand la branche disparaît) | **la boucle** (Pony), pour le compte de l'orchestrateur | `feature-up.sh` (ouverture, réouverture), `deliver.sh` (le push de la tête du worktree) |
| `screenshots` | branche orpheline des captures, `<pr>/<carte>/*.png` | la boucle | `deliver.sh`, par la plomberie git (index temporaire, `write-tree`, `commit-tree`), sans checkout |
| `staging` (`FACTORY_STAGING`) | validé par l'humain ; le client y teste | **EVA** | `eva-merge.sh`, sur approve ou ordre |
| `main` (`FACTORY_TRUNK`) | la production | **EVA** | `eva-release.sh`, sur ordre |
| tout le reste | | **l'humain** | |

**Ce qui empêche l'orchestrateur de pousser, et ce qui ne l'empêche pas.** La
boucle frappe **deux** jetons d'App par tour : le complet, qu'elle garde pour
ses gestes (`feature-up.sh` et `deliver.sh` reçoivent nommément le credential
helper de `gh` ; le fetch de fraîcheur et le sous-module portent le jeton en
en-tête `extraheader`), et un jeton **réduit**
(`gh-app-token.sh --agent` : `contents: read`, `issues: write`,
`pull_requests: write`, `metadata: read`) qui devient le `GH_TOKEN` de
l'orchestrateur et des rôles, lancés avec `env -u FACTORY_TOKEN -u
GIT_CONFIG_*`. Un `git push` de l'agent est refusé par GitHub, pas par une
consigne. Sa limite, dite dans `factory.mk` : l'agent tourne sous le même uid
que la boucle et lit le `.env`, il *peut* refrapper un jeton complet — la
porte ferme la négligence, pas la triche (voir « Ce que la porte ferme »).

**Ce qui empêche la boucle d'écrire sur `staging` et `main`.** Aucun script
de la boucle ne les nomme comme cible d'écriture ; `gh-release.sh`,
`eva-merge.sh` et `eva-release.sh` refusent en 3, avant toute lecture de
configuration, quand `FACTORY_IN_LOOP` est posé (la boucle l'exporte à chaque
tour) ; les deux d'EVA exigent **en plus** ses identifiants (`EVA_GITHUB_DIR`, par `eva-token.sh`) — jamais
`FACTORY_TOKEN`, même retiré de l'environnement : un agent du tour qui
retirerait la variable se heurte à l'absence des identifiants.

**Pas de serrure GitHub par défaut.** Un dépôt privé en plan gratuit n'a pas
de protection de branche ; la garantie est : une seule identité écrit sur une
branche partagée, sur un ordre humain tracé, et le code refuse tout autre
chemin. Un ruleset payant peut s'y ajouter ; il ne remplace pas la règle.
La garde `branches_require` (`lib.sh`) refuse encore en 3 deux branches
égales — une feature mergée irait directement en production.

## Le tour

Un processus **neuf** par carte : Claude Opus 5 (`CLAUDE_LAUNCH`, effort low)
lancé dans le worktree de la feature avec un prompt court (`LOOP_PROMPT`) —
la carte, sa feature et sa PR, le worktree, la racine de l'arbre principal, la
base (le SHA de `origin/feature/<F>` à l'admission, écrit **une fois** dans
`.omc/turn/<n>/base`). La procédure vit dans le skill `orchestrator`. **Il
n'écrit pas de code et ne pousse jamais** : il compose l'équipe et fait poper
chaque rôle par `role.sh <rôle> <carte> <worktree> <base> [entrées…]`.

**Le socle, exigé dès que le diff touche du code** — ce qui se décide sur
`git diff --name-only`, par une liste blanche de formats inertes (`.md`,
`.txt`, `.rst`, `.adoc`, `LICENSE*`, `CHANGELOG*`, `.editorconfig`,
`*.env.example`, `CODEOWNERS`), pas sur la parole de l'analyste ; un workflow
de CI, un `package.json`, un `.toml`, un `.lock` sont du code. Une carte doc
s'en passe sur justification écrite dans `socle-omis.md` — **non vide**, la
porte refuse un fichier vide.

1. **`analyste`** (Opus 5) : l'état des lieux, descriptif ; `analyse.json`
   porte `refacto` (`aucune` · `petite` : ≤ `FACTORY_REFACTO_MAX` fichiers,
   aucune interface publique → l'orchestrateur **carve** une carte de refacto,
   sous-issue du même parent, `factory:priority`, qui bloque la carte par
   dépendance native, rend la carte et s'arrête — le coût de la dette est
   visible dans la progression · `grande` → `needs-human`) et
   `comportement_documente`.
2. **`codeur`** (Codex `gpt-6-astra`) : implémente, joue `VERIFY.md`, commite
   sur la branche courante avec `Refs #n` (jamais `Closes`), ne pousse pas.
3. **`relecteur-maint`** (Opus 5 — une autre famille que le codeur par
   défaut ; rien dans le code ne vérifie que les deux familles diffèrent, un
   `factory.conf` peut les confondre) : `ok` / `changements` (le codeur est
   relancé avec le rapport) / `illisible`. **N = `FACTORY_REVIEW_MAX`** (2)
   **passes** au plus : `k` est 1 + le plus grand numéro déjà écrit pour le
   rôle, donc un CLI en échec (4) qui a laissé son `.prompt.md` consomme une
   passe ; `role.sh` refuse en 5 la passe N+1, sans rien lancer, et le
   désaccord devient `needs-human` — on ne pousse pas « en notant ».
4. **`relecteur-secu`** (Fable 5.1) : `ok` / `faille` → `needs-human` direct,
   sans relance, sans correction. Plus aucun commit de code après lui.
5. **`writer`** (Haiku 4.5) : seulement si `comportement_documente` **et**
   `DOCS.md` à la racine du dépôt ; un commit séparé `docs(...)`, le seul
   toléré après les relecteurs.

**Le catalogue est fermé** (`role_get`, `lib.sh`) : les cinq du socle plus
`test-engineer` (Fable 5.1), `designer` (Codex, avec captures),
`document-specialist` (Haiku 4.5). Un rôle hors catalogue : `role.sh` sort en
3, et son artefact ferait refuser le push. Chaque modèle se surcharge par
`FACTORY_ROLE_<RÔLE>` dans `factory.conf`. Un orchestrateur peut poser un
autre catalogue dans son shell et `role.sh` le suivrait ; ce qui protège est
que **la boucle rejoue la porte avec SA configuration** avant de pousser (plus
bas).

**Les artefacts**, sous `<racine>/.omc/turn/<carte>/` (jamais dans le
worktree, que la boucle ne lit pas). De `role.sh`, par passe : `<rôle>-<k>.prompt.md`,
`.brut` (la sortie du CLI telle quelle), `.md` (la réponse), `.stderr`, `.json`
(modèle attendu et **prouvé**, verdict, fenêtre `debut`/`fin`,
`head_avant`/`head_apres`, le chemin de la preuve) — jamais écrasés ; de
l'analyste, `analyse.json`. De la boucle : `card.json` (déposé par
`feature-up.sh` à l'admission, une fois), `base` (une fois), `turn-verify.out`
et `refus.md` (les motifs d'un refus, postés sur la carte), `needs-human` (le
marqueur, par `card-state.sh`). De l'orchestrateur : `socle-omis.md`,
`livraison.md`, `captures/*.png`, `pret`. Le
modèle est **inscrit par le CLI** : `modelUsage` dans la sortie JSON de
claude, `turn_context` du rollout codex que l'artefact nomme (retrouvé par le
`thread_id` de `thread.started`) — jamais déclaré par l'agent.

**La porte** (`turn-verify.sh <carte> <worktree> <base>`) liste **tous** ses
motifs et refuse le push (1) sur chacun de ceux-ci :
- le diff `<base>..HEAD` est vide ;
- un `<rôle>-<k>.json` illisible (pas un objet JSON) ; un `.md`/`.brut` dont le
  `.json` manque (« artefact supprimé ») ; un rôle hors catalogue ;
- un modèle non prouvé : l'artefact ne prouve rien, ou son modèle prouvé
  n'est pas celui du catalogue **relu ici** (jamais le `modele_attendu` de
  l'artefact), ou la preuve ne se recalcule pas — brut absent, `modelUsage`
  sans ce modèle, rollout absent ou d'un autre thread, `turn_context` d'un
  autre modèle ;
- le relecteur sécurité a rendu `faille`, sur n'importe quelle passe ;
- pour le dernier relecteur `ok` de chaque famille : pas de `head_apres` ; sa
  tête n'est plus un ancêtre de HEAD (branche réécrite) ; des commits après
  sa tête touchent du code ;
- un commit tombé dans la fenêtre d'aucun rôle qui écrit (codeur, writer,
  designer, test-engineer) — c'est ce qui rend « un agent seul est interdit »
  vérifiable ;
- quand le diff touche du code : pas d'analyste `ok` prouvé ayant vu la base ;
  pas de codeur valide ; pas de relecteur-maint, ou son dernier verdict n'est
  pas `ok`, ou plus de N passes ; pas de relecteur-secu, ou son dernier verdict
  n'est pas `ok` ;
- quand il n'en touche pas : `socle-omis.md` absent ou vide ;
- `comportement_documente` avec `DOCS.md` et sans writer valide.

Une base ou un diff incalculables sont un 3, jamais un « rien à pousser ».

**Puis la boucle, dans SON environnement.** L'orchestrateur joue la porte et
pose `pret` ; la boucle la **rejoue** avec sa configuration (catalogue,
`FACTORY_REVIEW_MAX`, `CLAUDE_BIN`…) — un orchestrateur qui aurait posé
`FACTORY_ROLE_RELECTEUR_SECU=haiku` dans son shell verrait sa porte s'ouvrir sur
un artefact que celle de la boucle refuse. Sur 0, `deliver.sh` ; sur tout code ≠ 0,
`pret` est consommé, les motifs sont postés sur la carte (`gh-comment.sh`) et la carte
sera reprise. **Un `pret` déjà posé saute l'orchestrateur** : le tour d'avant a
fini, c'est la livraison qui a raté (un 5xx) — on va droit à la porte.

**Ce que la porte ferme, et ce qu'elle ne ferme pas.** Elle protège contre un
orchestrateur qui **néglige** — socle absent, verdict rouge, commit hors
fenêtre, modèle non prouvé — et contre un push direct (jeton réduit). Elle ne
protège pas contre un qui **triche à uid égal** : il tourne sous le même
utilisateur que `role.sh`, peut fabriquer un `.brut`, un rollout, un artefact,
ou refrapper un jeton complet depuis le `.env`. Fermer cette classe — `role.sh`
sous un uid distinct, artefacts signés — est un chantier d'`EVOL.md`. **Il n'y
a pas de budget par tour dans le code** (§ 8 de la spec le prévoyait) :
`LOOP_MAX_RETRY` borne les retours d'une carte, rien ne borne la durée ni le
coût d'un tour.

**Les captures** : `.omc/turn/<carte>/captures/*.png`, poussées par
`deliver.sh` sur `screenshots` sous `<pr>/<carte>/` (10 Mo par image, au-delà
la ligne le dit) et inlinées par `blob/screenshots/<pr>/<carte>/<f>?raw=true` —
la seule forme mesurée (4 août 2026) qui s'affiche sur un dépôt privé ;
`raw.githubusercontent.com` rend 404 dans un navigateur. L'API n'accepte pas
d'image dans un commentaire avec un jeton d'App.

## Les previews

**Une preview par PR de feature, sur la machine, pour l'humain seul** (§ 2,
§ 8 de la spec) : le serveur du worktree `.worktrees/feature-<F>`, exposé
**par port** — `FACTORY_PREVIEW_PORT_BASE + F`, 8100 par défaut, donc
`http://<FACTORY_PREVIEW_HOST>:8112` pour la feature 12 —, **publié par le
crochet sur l'adresse LAN de la machine, explicitement** (`-p <ip
lan>:<port>:8010`), jamais sur `0.0.0.0` : docker publie un port par DNAT,
en amont du pare-feu de l'hôte, qui ne voit pas ces ports — une règle
`allowedTCPPorts` n'y changerait rien, dans un sens comme dans l'autre. Ce
qui tient « LAN seulement, jamais Internet », c'est l'adresse de publication
et le réseau où vit la machine (rien ne redirige ces ports depuis
l'extérieur). Avec **une base par PR remplie par les seeders** du dépôt. Pas
de proxy, pas de DNS wildcard : le réseau n'en a pas.

**Ce que l'humain y perd, et qui est voulu.** La base est recréée à neuf
(`migrate:fresh --seed`) à chaque montage — chaque carte UI livrée, chaque
redémarrage : ce qu'il a saisi dans la preview disparaît. Ce qui doit se voir
à la relecture est dans les seeders, et un seeder qui ne raconte pas assez est
une carte « enrichir les seeders », jamais un dump. La preview suit **l'arbre
vivant** du worktree (monté en lecture seule : elle n'y écrit rien), pas la
tête livrée : entre deux livraisons, un commit local de l'agent s'y voit.

**Le fait qui donne sa forme au mécanisme : ni la boucle ni EVA ne peuvent
lancer `docker`.** La boucle tourne dans le conteneur `factory-loop`, EVA dans
`factory-eva`, sans socket docker ni `systemctl`. Tout ce qui démarre un
conteneur tourne sur l'**hôte**, par une unité systemd ; la boucle et EVA ne
font que **déposer une demande** dans un registre partagé.

**Le registre** (`bin/preview.sh`), sous `$FACTORY_STATE/previews/` — deux
répertoires créés par `nix/preview.nix` (tmpfiles, 0770 usine), montés dans le
conteneur d'EVA sous `/previews/requests` (écriture) et `/previews/state`
(lecture) :

- `requests/<F>` : `up <epoch> <origine>` ou `down <epoch> <origine>`, une
  demande par feature, la dernière écrase la précédente. L'origine dit qui :
  `deliver:#<carte>` (la boucle, à la livraison d'une carte UI), `eva:<login>`
  (EVA, sur le mot d'un utilisateur autorisé — skill `factory-preview`),
  `reap` (l'hôte). Une demande traitée est effacée — **si elle est encore
  celle qu'on a lue** : réécrite pendant un crochet (une carte livrée
  entre-temps), elle reste et repart au passage suivant. Ce que `reconcile`
  ne reconnaît pas — un nom qui n'est pas un numéro de feature (`08`, un
  brouillon, un `README`), un verbe ni `up` ni `down` — est dit et laissé,
  jamais effacé. Le numéro de feature est un entier **sans zéro de tête** ;
  `request up 08` est un 3 ;
- `.tmp/` : les brouillons des écritures, renommés en place — hors de
  `requests/`, que systemd surveille ;
- `state/<F>.json`, **écrit par l'hôte seul** : `port`, `conteneur`, `base`,
  `url`, `head` (la tête du worktree montée), `started`, `expires`,
  `origine` — ou `etat: erreur` avec la sortie du crochet.

**Qui demande.** `deliver.sh`, après le push et les captures, **si la carte
est UI** — des captures dans `captures/`, ou un artefact `designer-<k>.json`
prouvé (la même preuve que la porte lit) — dépose `up` et écrit dans le
commentaire de livraison « Preview : http://<host>:<port> (sera montée sur la
machine en quelques minutes, LAN seulement) » : l'adresse où elle *sera*,
au futur. Une carte sans UI ne demande rien. **L'hôte de l'URL** est
`FACTORY_PREVIEW_HOST` ; à défaut le nom de la machine (`hostname`, ou
`/proc/sys/kernel/hostname` quand la commande n'est pas sur le PATH d'une
unité, sinon `localhost` — jamais une adresse 127) ; **dans un conteneur sans
la clé, la demande est refusée en 3** : le nom y est l'identifiant du
conteneur, et il finirait dans une PR. EVA dépose `up` ou `down` sur
demande (`preview.sh request`), relit `preview.sh status` au plus deux
minutes, et rend l'adresse sans jamais promettre qu'elle y est déjà ;
`eva-watch.sh --etat` liste les previews en dernière section (h) — elles ne
pingent pas, une preview n'attend personne.

**Qui exécute** (`nix/preview.nix`, sous l'utilisateur d'usine, docker, curl
et `ip` sur le PATH) : `factory-preview.path` surveille `requests/` et lance
`preview.sh reconcile` à chaque changement — pour un `up` : s'il n'y a pas
d'état, si la **tête du worktree a changé** depuis l'état (une carte de plus
livrée), ou si le conteneur n'est plus là, il appelle le crochet
`preview-up <F> <worktree> <port>` — qui ne rend 0 que quand l'application
**répond** — et écrit l'état ; sinon il ne fait que repousser l'échéance ;
pour un `down` : `preview-down <F>`, l'état effacé. Un seul passage à la fois
(`flock`, dix minutes au plus, sinon dit et 4). `factory-preview-reap.timer`,
toutes les dix minutes, lance `preview.sh reap` **puis `reconcile`** — ce que
le path a raté (une demande d'avant le démarrage, une demande arrivée pendant
qu'une unité tournait) est rattrapé sous dix minutes. Le reap : `down` pour
tout état **expiré** — `FACTORY_PREVIEW_TTL` secondes, 8 h par défaut, depuis
la dernière demande `up` (l'inactivité HTTP n'est pas mesurée, il n'y a pas
de proxy pour la voir) —, dont le **worktree n'existe plus** (`wt-cleanup.sh`
l'a retiré parce que la PR est mergée ou fermée, et il n'a rien à savoir des
previews : le reap suit les worktrees), ou **en erreur** — rejoué à chaque
reap, dans les deux cas : un `down` est idempotent et bon marché, il retire
ce qu'un crochet a laissé à moitié, et l'état disparaît quand le nettoyage
passe (la cause reste dans le journal).

**Ce qui n'arrête jamais l'usine.** Sans crochet `preview-up`/`preview-down`
chez le consommateur : dit une fois, rien fait, 0. Un crochet en échec : état
`erreur` avec sa sortie (ce qu'EVA rapporte), demande effacée (on ne rejoue
pas un échec toutes les dix minutes), code 1 — **jamais 3** : une preview est
un confort de relecture, pas une garantie, et `deliver.sh` livre avec ou sans.

## Les remarques

Pony ne réagit jamais à un commentaire brut : il exécute une carte.
`gh-pr-attention.sh` est du ménage, à chaque tour, rien sur stdout :

- **chaque remarque de `FACTORY_HUMAN_LOGIN`** sur une PR de feature ouverte
  — review (sauf `APPROVED`, avec ou sans corps : l'approbation est
  l'approbation), commentaire de conversation, commentaire de ligne — devient
  une **carte** : sous-issue de la feature (GraphQL `addSubIssue` ; pour une
  mini-feature, sous-issue de la carte racine), `factory:priority`, le
  commentaire cité, son lien, `fichier:ligne` ; corps marqué
  `<!-- factory:remarque <id> -->` et `<!-- factory:fil <pr> ligne <racine> -->`
  ou `<!-- factory:fil <pr> conversation -->` ;
- puis l'usine **répond dans le fil**, sous `FACTORY_BOT_LOGIN`, « → #M »
  avec la même marque — dans le fil de ligne (`…/replies`, à la racine du fil
  : GitHub ne répond qu'à elle), en conversation pour une review. **La marque
  est la seule preuve** ; la « règle du dernier mot » de la v1 ferait perdre
  toute remarque suivie d'un commentaire de livraison. Une carte créée dont la
  réponse a raté (5xx) est retrouvée au tour suivant dans les sous-issues de
  la feature, ouvertes et fermées, par sa marque, et seule la réponse « → #M »
  est rejouée — jamais une seconde carte ;
- **une CI rouge** sur une PR de feature ouverte devient une carte « Réparer
  la CI de feature/<F> », marquée `<!-- factory:ci feature/<F> -->`, recréée
  seulement si aucune sous-issue ouverte ne la porte.

Périmètre : les PR dont la tête est `feature/<F>` **du dépôt lui-même** ; ni
fork, ni PR de release. Trois lectures par PR de feature ouverte (reviews,
conversation, lignes), paginées — il y a peu de PR de feature ouvertes à la
fois, c'est ce qui rend le coût acceptable. Une carte créée dont le
rattachement (`addSubIssue`) est refusé passe `needs-human` : sans parent,
elle deviendrait une mini-feature.

À la livraison, `deliver.sh` relit ces marques dans le corps de la carte et
poste « #n : Livrée dans … » **dans le fil d'origine** : celui qui a fait la
remarque la voit livrée là où il l'a faite.

## La release

**À blanc par défaut, dans les deux scripts**, parce qu'ils ferment des
features que personne ne rouvrira ; la liste est la même à blanc et en
écriture, sinon le mode à blanc ne sert à rien.

**`eva-release.sh`** (EVA, sur « ok c'est good, on sort une version ») :

- à blanc : fetch authentifié par le jeton d'EVA ; la plage « dernier tag
  contenu dans `origin/main` `..` `origin/staging` » (première release : toute
  l'histoire, dit) ; les `Refs #n` des commits — et les mots-clés `Closes`, `Fixes`,
  `Resolves`, que le motif accepte aussi pour les dépôts qui les écrivent
  encore ; jamais un `#N` nu, le squash de GitHub colle le numéro de la
  **PR** au titre — remontés à leurs features par `gh-feature.py lot` (un
  parent introuvable est un 3 : une lecture en échec n'est jamais « pas de
  parent ») ; puis `version: vX.Y.Z (motif)`, `plage:`, `tete: <sha de
  staging>`, et la liste. Le numéro est **proposé** : minor si le lot porte au
  moins une issue de type Feature, patch sinon ; `--version` l'impose — un
  numéro qui ne monte pas au-dessus du dernier tag est un **3**, avant
  d'écrire. **Refus (1)** : une feature complète sans
  `factory:staged` (« pas passée par EVA », on repose le label si c'est un
  accident, jamais forcé) ; une feature incomplète (une carte du lot ouverte,
  ou `completed < total`), sauf `--force-incomplete`, geste humain ; rien à
  sortir. Une Feature citée directement par un commit, une PR, une référence
  morte sont dites et laissées hors du lot ; un 403, un parent hors dépôt
  arrêtent en 3 ; **la feature permanente des alertes** est listée
  « ni fermée ni bloquante » et n'entre dans aucun refus ;
- `--apply --ordre "slack:<ts>" --version X.Y.Z --tete <sha>` — les trois
  exigés, et la tête refusée si `staging` a bougé depuis ce qu'on a montré :
  `POST /merges` `staging` → `main` (merge commit, message « Release vX.Y.Z /
  ordre : <ref> » ; 409 = conflit, refus 1, rien d'écrit ; 204 = rien à
  merger, le SHA est relu sur la tête de `main`), le tag sur le SHA rendu
  (déjà là sur ce SHA : second passage ; sur un autre : numéro pris, 3), la
  release GitHub avec les notes (une ligne par feature, ses cartes en
  sous-liste), `gh-release.sh --apply`, puis la CI de `main` sondée sur ce SHA
  (`FACTORY_RELEASE_WAIT` 1800 s, toutes les `FACTORY_RELEASE_POLL` 30 s, un
  raté passager toléré). **La dernière ligne de stdout est le verdict** :
  `deploiement: success|failure|timeout|inconnu` (`inconnu` : la lecture des runs a
  été refusée — droits `Actions` de l'App d'EVA ? — la version est sortie quand
  même, code 1), suivi de `; fermeture: a-rejouer` si `gh-release.sh` a échoué
  — la release est sortie quand même. Une release qui ne contient que des
  cartes de la feature permanente des alertes est proposée en **patch** : cette
  feature n'est pas une nouveauté.

**`gh-release.sh`** (appelé par EVA ; à la main, sans `--apply`, il liste) :
la version est **dérivée**, jamais un argument — le tag le plus récemment
créé parmi ceux que `origin/main` contient, lu après un fetch ; la plage est
le tag précédent dans la production. Pour chaque feature du lot, dans l'ordre
des numéros : les cartes reçoivent « Sortie dans `vX` » (marque
`<!-- factory:release vX -->`, relue avant d'écrire : rejouable) ; une carte
ouverte reçoit un autre texte et n'est pas fermée ; une feature complète et
`staged` reçoit la trace, perd le label (`DELETE`, 404 toléré, tout autre
refus arrête pour être rejoué), et est **fermée en dernier** ; déjà fermée :
trace et label ; incomplète ou sans label : dite, laissée ouverte ; la feature
permanente des alertes : ses cartes commentées, son label retiré s'il est là,
jamais fermée, dit. Une pause d'une seconde après chaque commentaire de carte
et après chaque fermeture (la limite secondaire de GitHub est de l'ordre de
80 écritures par minute).

**Ce qui le rend humain.** `FACTORY_IN_LOOP` → 3 en tête des trois scripts
(`gh-release.sh`, `eva-merge.sh`, `eva-release.sh`) ; les deux d'EVA exigent
en plus ses identifiants. Le skill `factory-release` fait confirmer le numéro
et la tête avant `--apply`.

## Les pings et les relances

**`eva-watch.sh`** est la source unique de « ce qui attend un humain », triée
et sans horodatage : (a) les cartes `factory:needs-human` ouvertes, avec leur
nature — `carte` (le marqueur `.omc/turn/<n>/needs-human`, un label de cycle,
ou une Feature au-dessus ; on la débloque, on ne la ferme jamais) ou
`cadrage` (le reste ; se ferme une fois tranché) ; (b) les PR de feature
prêtes sans approbation de `FACTORY_HUMAN_LOGIN` sur leur tête courante — ni
brouillon, ni PR qui porte `factory:needs-human` (c'est une décision), ni PR
de fork, ni PR de carte ; (c)
les features `factory:staged` (le stock) ; (d) les PR de feature à CI rouge ;
(e) `.omc/loop.halt` ; (f) `.omc/loop.file-vide` ; (g) les **cartes
d'alerte** ouvertes — les sous-issues de `FACTORY_SECURITY_FEATURE`, ou, sans
clé, les issues ouvertes qui portent la marque `<!-- factory-security:… -->`
de `gh-security-triage.py` — dont la sévérité, telle que le triage l'écrit
(« [high] » dans un titre CodeQL, « **critical** » dans un corps ; un secret
exposé est écrit `critical`), est critical **ou high** : les deux pingent,
sous le même mot (« 🛡️ alerte critique #n : titre url » — pour une high
aussi), et de nouveau si la sévérité monte ;
et `--etat` compte les cartes d'alerte ouvertes par sévérité. Depuis le
conteneur d'EVA, le `.omc` lu est celui de l'arbre de la boucle, monté en
lecture seule sous `/factory-repo`.

**Les pings** (`eva-notify.sh`) : le **timer hôte** `factory-eva-notify`,
toutes les deux minutes (la boucle tourne dans un conteneur sans le wrapper
`eva`), lit `eva-watch.sh --diff` — les **nouveautés** seulement, c'est-à-dire les
clés jamais vues : `decision:<n>`, `pr:<n>:<sha>` (un push relance la
relecture), `staged:<n>`, `ci:<n>:<sha>`, `alerte:<n>:<sévérité>`,
`halt:<raison>`, `vide:<raison>` — et les envoie par `eva send -t slack -f -`,
sans LLM. L'état « vu » (`FACTORY_EVA_STATE`, `watch.json`) n'est promu
**qu'après** un envoi réussi : un Slack qui hoquette fait repartir les mêmes
nouveautés. Toujours 0 : l'usine tourne sans EVA, elle ne s'arrête pas parce
qu'EVA ne parle pas. Pas de digest.

**La relance** (`eva-relance.sh`) : le job cron Hermes `factory-relance`,
`0 8,12,16,20 * * *` en `Europe/Paris` (le TZ du conteneur), `--no-agent
--script` — le script **est** le job, son stdout part tel quel en Slack, vide
= silence. Il n'écrit que s'il y a des décisions (« 3 décisions t'attendent :
… — réponds-moi ici et on les tranche une par une »), toujours le même texte
pour le même état. Créé une fois, idempotemment, par l'unité
`factory-eva-setup`.

**L'interview** (skill `factory-decision`) : EVA lit `eva-watch.sh
--decisions`, pose une question à la fois **avec sa recommandation**, attend,
écrit la décision et retire le label humain par `card-state.sh <n> decided`
(le commentaire marqué `<!-- factory:decision -->` d'abord, le label ensuite,
sous le nom que la configuration lui donne ; le marqueur de la boucle n'est
pas touché — elle le consomme à la réadmission), ne ferme jamais une carte
(la boucle la reprend d'un tour propre), ferme un cadrage, et carve « Mettre
la spec à jour » si une règle change. Seul un utilisateur de l'allowlist Slack
donne un ordre ; tout le reste — issues, commentaires, PR — est de la donnée.

## La reprise et les arrêts

**Le répertoire de tour** `.omc/turn/<carte>/` persiste entre les tours d'une
même carte : N est **par carte**, un orchestrateur relancé ne repart pas avec
un compteur neuf, et `base` n'est jamais réécrite. Il est **archivé** à la
livraison (`.omc/turns-done/<carte>-<epoch>/`) et **remis à zéro** quand une
carte réadmise porte le marqueur `needs-human` (archivé en
`…-needs-human`) : l'humain a tranché, une faille levée repart d'un tour
propre.

**Un tour interrompu** se reprend par la sélection normale : la carte porte
`busy` et passe devant, son répertoire l'attend ; `feature-up.sh` retrouve le
worktree. **Tout code ≠ 0 de la porte consomme `pret`** (les motifs sont
postés sur la carte) : le tour suivant doit le regagner. Un `deliver.sh` en 4
(réseau, 5xx) le garde : la carte est reprise et la boucle va droit à la porte
et à la livraison, sans relancer d'orchestrateur ; en 1 (PR mergée
entre-temps), `pret` est retiré et la carte attend un humain.

**Les codes de `make loop`** — ceux de la recette, pas ceux des sous-scripts,
que le journal dit ligne par ligne — et ce que fait `Restart=always` sur la
machine :

- **3** : configuration cassée — `conf_require`, `branches_require`, un jeton
  impossible à frapper, un 3 de `wt-cleanup`, `gh-unblock`, `gh-pr-attention`,
  du sondage, de `feature-up` (ou une carte de type Feature), de `deliver`.
  Arrêt. Sous `Restart=always`, une relance repasse par le même mur : jeton,
  fetch, ménage, et ressort en 3 — du journal, pas de tour. **Sauf pour
  `deliver.sh` en 3**, où `pret` est conservé : la relance irait droit à la
  porte puis à la livraison, et ressortirait en 3 toutes les trente secondes
  sur la même carte ; la boucle pose donc `.omc/loop.halt` avec la raison
  (« deliver.sh a rendu 3 sur #n … ; pret est conservé ») avant de sortir ;
- **4** : le **tourniquet** — `.omc/loop.halt` posé, ou déjà présent au
  démarrage (voir ci-dessous). Un raté passager d'un sous-script (4) ne fait
  **pas** sortir la boucle : elle dort `LOOP_SLEEP` et resonde ;
- **5** : l'arbre principal n'est pas sur `staging`, au démarrage ou en cours
  de route ; **1** : le CLI de l'orchestrateur est introuvable ;
- **0** : `make loop-stop` (`.omc/loop.stop`), relu en tête de chaque tour et
  après chaque tour — la carte en cours finit ; le sentinelle d'un run
  précédent est purgé au démarrage. (Le marqueur `/etc/factory-loop.paused`
  que la spec nomme pour la migration de Paris Showroom n'est lu par aucune
  unité de `nix/` : arrêter la boucle sur la machine, c'est `systemctl stop
  factory-loop`, ou `loop.halt`. Un hôte peut le porter lui-même — un
  `ConditionPathExists = "!/etc/factory-loop.paused"` sur `factory-loop` dans
  sa configuration, ce que celui de Paris Showroom fait.)

**Le tourniquet** (`LOOP_MAX_RETRY`, 3) : `.omc/loop.retry` porte « sujet
compte depuis », **sur disque** — sous `Restart=always`, un compteur en
mémoire repartait de zéro à chaque relance, `LOOP_MAX_RETRY` par vie de
processus, un processus neuf toutes les trente secondes. Ce qu'il compte :
**chaque tour servi sur la même carte d'affilée**, qu'il ait avancé ou non — un
refus de la porte, un `deliver` en 4, un orchestrateur mort comptent tous ; le
compteur repart à 1 dès que le sondage sert une autre carte. **Une carte a N
tours au plus** : le (N+1)ᵉ écrit `.omc/loop.halt` (« reprise N fois sans
avancer ») et sort en 4, **avant** de lancer l'orchestrateur. Le compteur se
**périme** : plus vieux qu'un jour, il est ignoré — mais la péremption n'est
évaluée qu'**au démarrage** de `make loop`, pas entre deux tours (une carte
qui revient légitimement des jours plus tard n'est pas un tourniquet ; une
boucle qui tourne depuis trois jours sur la même carte, si). **`loop.halt` est
relu en tête de chaque démarrage** : une relance s'arrête en une ligne, en 4,
et dit d'effacer **`loop.halt` et `loop.retry`** — les deux, sinon la relance
repart avec le compteur plein et halte au premier tour. EVA le voit (e).

**`.omc/loop.file-vide`** : écrit quand le sondage rend 1, avec la raison
générique (le journal du sondage dit laquelle), effacé dès qu'une carte est
servie. EVA le voit (f) ; la boucle dort `LOOP_SLEEP` et resonde.

## Ce que le dépôt consommateur fournit

- **`VERIFY.md`** à la racine : ce que « vérifié » veut dire ; le codeur le
  joue avant chaque commit, un commit qui ne passe pas reste dans le
  worktree. Absent, le contrat est `make verify`.
- **`DOCS.md`** (facultatif) : où vit la documentation, comment on la
  construit, le ton, la langue. Absent → pas d'étape writer, la porte le dit.
- **`factory.conf`** (versionné) et **`.env`** (secrets) — les clés sont dans
  [`configuration.md`](configuration.md) : le dépôt, les deux branches, le
  jalon, l'identité de commit, `FACTORY_HUMAN_LOGIN`, `FACTORY_BOT_LOGIN`, les
  labels, le catalogue des rôles, `FACTORY_REVIEW_MAX`, `FACTORY_REFACTO_MAX`,
  l'App de Pony.
- **Les crochets** `tools/factory-hooks/` : `worktree-up <nom> <base>` (la
  base d'une feature, ses seeders, sa route ; doit laisser le worktree sur
  `feature/<F>`), `worktree-down`, `housekeeping`, `run-loop-args`,
  `env-overrides`, et, pour les previews (« Les previews » plus haut, appelés
  par l'**hôte** sous l'utilisateur d'usine) : `preview-up <F> <worktree>
  <port>` — crée la base de la PR si elle manque, la migre et la seede, lance
  le serveur du worktree sur `<port>`, remplace un conteneur du même nom,
  imprime le nom du conteneur (ligne 1) et celui de la base (ligne 2,
  facultative), et **ne rend 0 que quand l'application répond** (sinon ses
  journaux sur stderr, le conteneur retiré, 1) ; publie sur l'**adresse LAN
  explicite**, jamais `0.0.0.0` ; monte le worktree en lecture seule — et
  `preview-down <F>` — retire le conteneur et la base, idempotent. Absents,
  l'usine tourne sans preview.
- **`FACTORY_PREVIEW_HOST`** dans `factory.conf` : le nom par lequel l'humain
  joint la machine sur le LAN — le défaut, le nom de la machine, est faux
  depuis un conteneur, et une demande y est refusée sans la clé.
- **`.claude/skills/orchestrator`** : un lien vers
  `tools/factory/skill/orchestrator` — c'est ce que Claude charge quand le
  prompt dit « suis le skill ». Les skills de rôle (`skill/roles/*.md`) sont
  lus par `role.sh` dans le sous-module, rien à lier. Les skills d'EVA
  (`skill/eva/*`) sont provisionnés par `nix/eva.nix` dans son conteneur,
  rien dans le dépôt consommateur.
- **`Makefile`** : `include tools/factory/factory.mk`.
- **Les labels** `factory:*`, semés par `gh-seed-labels.sh` sous les noms de
  la configuration ; le type d'issue `Feature` actif sur l'organisation.
- **Une feature permanente pour les alertes** (`FACTORY_SECURITY_FEATURE`) :
  une issue de type Feature, ouverte, sous laquelle `gh-security-triage.py`
  rattache chaque carte qu'il crée. **La raison : sans feature permanente,
  une alerte = une PR.** Dans la v2, une carte sans Feature au-dessus d'elle
  est sa propre mini-feature — une branche `feature/<n>`, un worktree, une PR
  brouillon, un merge d'EVA sur ordre, une ligne de release — et un tour de
  ménage qui transpose dix alertes ouvre dix chemins vers `staging` que
  l'humain relit un par un. Sous une feature permanente, les cartes d'alerte
  sont un lot sur une seule branche, relu comme les autres. **Elle est hors
  des règles de release** : `gh-release.sh` commente ses cartes sorties et
  retire `factory:staged` mais ne la ferme jamais (fermée, le triage sortirait
  en 3 au tour suivant — avalé par `|| true` — et plus aucune alerte ne
  deviendrait une carte) ; `eva-release.sh` ne la compte ni comme incomplète
  ni comme « pas passée par EVA » (une alerte encore ouverte ne bloque pas une
  release qui porte un correctif de sécurité). Les cartes d'alerte créées
  **avant** que la clé soit posée restent orphelines — le triage ne rattache
  qu'à la création ; elles se rattachent à la main. Sans la clé, le triage le
  dit à chaque tour. **Le crochet `housekeeping` du consommateur est invité à suivre la
  même règle** pour les cartes qu'il carve (chez Paris Showroom, le triage
  PostHog) : la clé est dans `factory.conf`, `addSubIssue` prend le node id de
  la feature et celui de la carte, et un rattachement refusé se dit par
  `card-state.sh <n> needs-human` plutôt que de laisser naître une
  mini-feature en silence.
- **Deux Apps GitHub, et leurs permissions — un geste humain, que rien ne
  vérifie** : celle de Pony (`Contents`, `Issues`, `Pull requests` en écriture,
  `Checks` et `Metadata` en lecture, les trois surfaces d'alertes en lecture
  pour le triage) et celle d'EVA (`configuration.md`, section EVA : `Contents`,
  `Pull requests`, `Issues` en écriture, `Checks` et `Actions` en lecture). Une
  permission changée doit être acceptée sur l'installation ; jusque-là, 403 au
  premier ordre, et les scripts nomment les lignes.
- **Sur la machine** (`nix/module.nix`, `nix/eva.nix`) : la clé de l'App de
  Pony sur le volume d'état, celles d'EVA sous `secrets/eva/`, l'allowlist
  Slack de Hermes — **la seule serrure sur qui ordonne**, et **un geste
  humain** : `SLACK_ALLOWED_USERS` dans `secrets/eva/runtime.env`, les IDs
  Slack séparés par des virgules (le format exact est celui de Hermes, voir sa
  doc), qu'aucune unité ne provisionne ; `factory-eva` refuse de lancer la
  passerelle si la clé est absente ou vide, et dit quoi poser —, le clone
  d'EVA rafraîchi avec son sous-module, le timer de pings, le cron de relance.

## Vérification

```bash
bash tests/run.sh          # hors ligne : faux curl, faux CLI, un origin nu
```

Ce que la suite tient, et qu'il ne faut pas laisser s'affaiblir : la porte
refuse un tour sans socle, sans preuve de modèle, avec une faille, un commit
hors fenêtre (`turn-verify.test.sh`) ; la boucle rejoue la porte et pousse
elle-même, l'agent part sans credential ni jeton complet (`loop.test.sh`) ;
`eva-merge.sh` refuse une approbation périmée, un fork, une CI absente, une
tête qui a bougé ; `eva-release.sh` refuse une feature incomplète ou sans
`factory:staged`, une tête qui a bougé, et rend le verdict en dernière ligne ;
`gh-release.sh` ne ferme jamais une carte, ne prend jamais un `(#34)` de
squash pour une carte, s'arrête sur un 403 au lieu de sauter la carte ; les
trois scripts refusent `FACTORY_IN_LOOP` avant le premier appel ; une remarque
n'est carvée qu'une fois (`gh-pr-attention.test.sh`) ; le triage rattache ses
cartes à la feature permanente, pose `needs-human` sur un rattachement refusé,
refuse une feature fermée avant toute carte, et laisse les cartes d'une surface
muette (`gh-security-triage.test.sh`, par le faux curl comme tout le reste) ;
une carte UI demande sa preview et l'adresse est dans la livraison, une carte
sans UI ne demande rien (`deliver.test.sh`) ; l'hôte ne rappelle le crochet
que sur une tête changée ou un conteneur disparu, éteint l'expiré et
l'orphelin, écrit l'erreur d'un crochet sans jamais rendre 3
(`preview.test.sh`, par un faux crochet et le faux docker).
