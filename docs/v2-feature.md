# La v2 : la feature comme unité de livraison

Un seul modèle, et il remplace celui de `docs/release.md` :

```
feature (issue) ─ cartes (sous-issues) ─ commits sur feature/<x> ─ PR relue par lot
        → staging (validé, le client teste)  → main (prod), sur un mot à EVA
```

**La PR redevient un lieu de relecture — mais une PR par feature, pas par
carte.** Ce document dit le fait qui l'impose, ce qu'il retire de la doctrine
actuelle, ce que le modèle gouverne, ce qu'il exige d'un dépôt consommateur,
et ce qui reste à vérifier avant la première ligne de code. Il a été établi le
18 septembre 2026 par interview, décision par décision ; les recommandations
écartées n'y figurent pas.

## Le fait qui rend ce document nécessaire

Le modèle « une porte par release » (`docs/release.md`) tient sur deux
conditions que sa propre doctrine déclare non négociables : la branche de
production est protégée par la forge, et la branche de travail est relue *au
fil de l'eau*. Sur Paris Showroom, le 17 septembre 2026, aucune des deux
n'était vraie : dépôt privé sur plan gratuit, donc aucune protection possible
(« une convention, pas une serrure », dit `factory.conf`), et personne n'a relu
`staging`. En seize heures de boucle, **quinze cartes ont été intégrées sans
qu'un humain ait vu un diff**, à côté de vingt-quatre commits d'autre chose. La
file s'est ensuite vidée sur quinze décisions humaines en attente — et rien ne
l'a dit à personne : le journal le répétait toutes les soixante secondes, EVA
avait une passerelle Slack ouverte, et aucun des deux ne parlait à l'autre.

Trois défauts distincts, qui sont le même :

- **La porte est au mauvais endroit.** Une PR de carte mergée automatiquement
  n'est relue par personne ; une release de quarante cartes n'est relisible par
  personne. Entre les deux, il n'y avait rien.
- **Un agent seul.** Le skill dit « composez l'équipe adaptée » et rien ne
  l'impose ; la variante Codex du prompt dit même « tu fais la carte de bout en
  bout toi-même ». Ni relecteur, ni preuve qu'un relecteur a tourné.
- **L'usine sait qu'elle attend un humain et ne le dit qu'à journald.**

## Ce qui disparaît de la doctrine actuelle

Nommément, pour qu'on ne le retrouve pas par habitude :

- **La PR de carte** (`card/<n>` → branche de travail) et son merge automatique
  par `gh-stage-pr.sh`. Une carte est un **commit** sur la branche de sa feature.
- **L'usine qui merge.** Pony ne merge plus jamais rien, nulle part.
- **La release comme geste manuel** (merge + tag à la main). EVA la fait, sur
  un mot.
- **Les labels de cycle sur les cartes** (`factory:delivered`,
  `factory:staged`). La carte se ferme à la livraison ; l'état « intégrée, pas
  sortie » se lit sur la feature.
- **L'agent neuf qui fait tout.** Le tour est une équipe orchestrée, et la
  boucle exige la preuve de chaque rôle obligatoire.
- **`FACTORY_IN_LOOP` comme refus de `gh-release.sh`** — il bloquait l'agent,
  il ne doit pas bloquer EVA. La garde se déplace : c'est *qui ordonne* qui est
  vérifié, pas *d'où* on appelle.
- **Le chantier n° 1 d'`EVOL.md`** (`factory doctor` vérifie la protection de
  branche) perd son objet : sans serrure par défaut, ce qu'on vérifie c'est que
  seule EVA écrit sur une branche partagée, et seulement sur un ordre autorisé.

## 1. L'unité : la feature

**Une feature = une issue GitHub de type Feature = une branche `feature/<x>` =
un worktree = une PR vers `staging`.** Ses cartes sont ses **sous-issues**
natives (GitHub : 100 par parent, 8 niveaux). La hiérarchie utile est
Feature → lot → carte : la vue de la feature montre six lots avec leur barre de
progression, pas cinquante-huit lignes.

**Pourquoi pas des tâches dans une seule issue.** Le bloc `[tasklist]` a été
retiré le 30 avril 2025 au profit des sous-issues. Une case `- [ ]` reste du
markdown : barre de progression et « convertir en issue », mais **aucun objet
API** — pas de numéro, pas de label, pas de dépendance, pas de `Refs #n`, pas de
fil de conversation. Tout ce que ce modèle décide suppose une carte adressable.

**Le rattachement est déterministe** : la sous-issue dit à quelle feature elle
appartient, une fois, à sa naissance. L'intelligence est là, et pas à
l'exécution : EVA *propose* un rattachement quand une carte naît orpheline, et
c'est l'humain qui confirme. Une carte qui reste orpheline (bug, demande
ponctuelle, correctif urgent) devient **sa propre mini-feature** — même flux,
pas de second chemin vers la production. Le hotfix est une feature d'une carte.

**Les décisions ne sont pas des features.** Les issues de cadrage (la map
Wayfinder et ses questions) restent des issues à part, hors de toute feature,
qui bloquent par dépendance native. Une feature qui « se fermerait » quand les
décisions sont prises mais le code pas sorti, c'est la confusion que le plan
du 17 septembre signalait déjà.

**Les piles.** La feature B qui déclare dépendre nativement de la feature A
part de `feature/A` ; sa PR vise `feature/A` ; GitHub la rebase sur `staging`
quand A est mergée. `gh-stack.sh base` lit déjà ces relations. Rien d'autre ne
fait une pile — pas « touche les mêmes fichiers », qui ne se voit qu'après.

**L'ordre de travail** dans une feature : dépendances natives, puis
`factory:priority`, puis l'ordre des lots (celui de la liste des sous-issues,
réordonnable à la souris — `reprioritizeSubIssue`), puis l'ordre des cartes dans
le lot. Entre deux features, la priorité de la feature.

**La vue** : un Project v2, table groupée par le champ natif « Parent issue »,
champ « Sub-issue progress » par feature, automatisations intégrées (issue
fermée → Done, PR mergée → Done). EVA y écrit le Status via GraphQL — un jeton
d'App le peut. Si les types d'issue ne sont pas ouverts aux organisations en
plan gratuit (non confirmé par la doc — voir « À vérifier »), un label
`feature` fait le même office sans changer le modèle.

**Fermeture** : la carte se ferme à la **livraison** — le commit est sur la
branche de feature, Pony a commenté la PR. La barre de la feature avance
pendant le travail. La **feature** se ferme à la **release**, par
`gh-release.sh`, qui relit les `Refs #n` de la plage et ferme les issues
Feature dont toutes les cartes sont sorties.

## 2. Les branches et les environnements

| Branche | Rôle | Qui y écrit |
|---|---|---|
| `feature/<x>` | le travail d'une feature | **Pony**, commits directs |
| `staging` | validé par l'humain ; le client y teste le consolidé (preprod) | **EVA**, au merge d'une feature |
| `main` | la production | **EVA**, à la release |

**Forward-only.** Pas de revert dans `staging` : ce qui y entre sort dans la
prochaine version. Une demande d'ajustement du client ouvre une nouvelle PR et
on travaille. Une feature n'est mergée dans `staging` que relue et approuvée —
c'est ce qui rend « tout ce qui y est sort » acceptable.

**Pony commite directement** sur la branche de feature, un commit par carte,
`Refs #n` dans le message, **seulement si la vérification du dépôt (VERIFY.md)
est verte localement**. La CI de la branche reste le passage obligé pour tout
déploiement. Le commit qui ne passe pas reste dans le worktree.

**Une preview par PR, obligatoire, sur la machine d'usine.** Le serveur du
worktree (l'application répond déjà sur son port dans le conteneur) est exposé
derrière un proxy, **à l'humain seul** — LAN ou VPN, jamais Internet. Le client
a `staging`. La preview monte quand Pony livre une carte UI (ses captures et le
coup d'œil humain regardent la même instance) *et* sur demande à EVA ; elle
s'éteint après inactivité ou à la fermeture de la PR. **Une base par PR,
remplie par les seeders du dépôt** ; si les seeders ne racontent pas assez, c'est
une carte « enrichir les seeders », jamais un dump.

**Plusieurs PR ouvertes en parallèle, un seul agent** qui dépile
séquentiellement. La machine n'a qu'une base et qu'un Redis pour l'agent ; la
concurrence est entre previews, pas entre agents.

## 3. Qui écrit sur les branches partagées

**Pony ne merge plus jamais rien.** Il pousse sur `feature/*`, et c'est tout.
Les permissions d'une App sont à l'échelle du dépôt : ce n'est pas le jeton qui
l'en empêche, c'est le code de l'usine et son skill — comme aujourd'hui pour
`main`, et pour la même raison.

**EVA est la seule main**, et elle n'agit que sur un ordre d'un utilisateur
Slack autorisé :

- **feature → `staging`** : sur l'*approve* GitHub de l'humain **ou** son mot en
  Slack. L'approbation **tombe à tout nouveau commit** sur la branche (une
  remarque devenue carte, livrée après l'approve) : EVA ne merge jamais un état
  que l'humain n'a pas vu. Merge commit, jamais squash — la release relit les
  `Refs #n`.
- **`staging` → `main`** : sur « ok c'est good pour le CRM, on sort une
  version ». EVA merge (merge commit), **propose un numéro semver** — minor pour
  des features, patch pour des correctifs — que l'humain confirme dans le même
  échange, tague, ferme les cartes et les features (`gh-release.sh --apply`),
  publie les notes de version sur la release GitHub, et confirme quand la CI a
  déployé la production.

**Pas de serrure GitHub par défaut.** La garantie est : une seule identité écrit
sur une branche partagée, sur un ordre humain tracé (le message Slack, l'approve
GitHub), et le code de l'usine refuse tout autre chemin. Un ruleset payant peut
s'y ajouter ; il ne remplace pas la règle.

## 4. Le tour : une équipe orchestrée, prouvée

**Claude Opus 5 orchestre et n'écrit pas de code.** Il compose l'équipe et
fait poper chaque rôle par son CLI — `codex exec`, `claude -p` — avec un
artefact en entrée et un artefact en sortie. **Un agent seul qui fait la carte
de bout en bout est interdit**, et la boucle le vérifie (plus bas).

**Le socle, obligatoire dès que le diff touche du code** — ce qui se vérifie
sur le diff (chemins, extensions), pas sur la parole de l'agent ; une carte
doc/config peut s'en passer, sur justification écrite dans l'artefact :

1. **L'analyste** — Opus 5. Avant toute ligne, un **état des lieux** du code que
   la carte va toucher : fichiers, comportements actuels, tests qui les
   couvrent, dette connue, et « touche un comportement documenté : oui/non,
   pages ». **Descriptif, jamais prescriptif** : il n'oriente pas
   l'implémentation, il fait gagner la lecture au suivant. Il rend un verdict
   « mettre au propre d'abord ? » : sous le seuil (≤ 5 fichiers, aucune
   interface publique) la refacto devient une **carte insérée avant, bloquante,
   auto-admise** — visible dans la vue et dans la PR comme un commit distinct ;
   au-dessus, la carte de refacto naît `needs-human` et EVA l'apporte. Le coût
   de la dette est *visible* dans la progression, pas enfoui dans un commit.
2. **Le codeur** — Codex `gpt-6-astra`.
3. **Le relecteur maintenabilité** — Opus 5, une autre famille que le codeur.
   **N = 2** allers-retours au plus ; au-delà, la carte passe `needs-human` avec
   le point de désaccord, **sans push**. Un désaccord persistant est un
   arbitrage, pas une chose qu'on pousse « en notant ».
4. **Le relecteur sécurité** — Fable 5.1. **Bloquant, sans plafond** : une
   faille = pas de push, `needs-human` direct. Une remarque de maintenabilité se
   discute ; une faille, non.
5. **Le writer** — Haiku 4.5, seulement si l'analyste a marqué « comportement
   documenté » **et** que le dépôt porte un `DOCS.md` à la racine (§ 6). Un
   commit séparé `docs(...)`, `Refs #n` : le même commit noierait la doc dans le
   diff ; une carte à part serait une doc qui arrive après la feature, donc
   jamais.

**Le catalogue des rôles optionnels est fermé** : *test-engineer* (Fable 5.1),
*designer/UI* (Codex, avec captures), *document-specialist* (Haiku 4.5, docs
officielles). Un rôle hors catalogue est refusé par la boucle : c'est un coût et
une identité que personne n'a validés.

**Les règles tiennent en bash, pas en prompt.** Chaque rôle est lancé par
`role.sh` et dépose sous `.omc/turn/<issue>/` (à la racine de l'arbre
principal, jamais dans le worktree) : `<rôle>-<k>.prompt.md` (le prompt
envoyé), `<rôle>-<k>.brut` (la sortie du CLI, telle quelle), `<rôle>-<k>.md`
(la réponse), `<rôle>-<k>.stderr`, et `<rôle>-<k>.json` (modèle attendu et
prouvé, verdict, fenêtre `debut`/`fin`, `head_avant`/`head_apres`) ; l'analyste
laisse aussi `analyse.json`. L'orchestrateur y écrit `card.json`,
`socle-omis.md` (la justification d'une carte doc sans socle), `livraison.md`
(le commentaire que la boucle poste) et `pret` (le signal du push). **Le
modèle est inscrit par le CLI**, jamais déclaré par l'agent. `turn-verify.sh`
**refuse** le push sur `feature/*` si un artefact obligatoire manque, si le
verdict sécurité n'est pas vert, si le compteur maintenabilité dépasse N sans
`needs-human`, si un rôle est hors catalogue, si un artefact porte un autre
modèle que celui du catalogue, si le dernier relecteur n'a pas vu la tête
poussée, ou si un commit n'est tombé dans la fenêtre d'aucun rôle qui écrit.
La liberté de composer l'équipe reste entière *au-dessus* de ce socle. C'est
la leçon du 17 septembre : une consigne sans vérification a laissé un agent
seul faire quinze cartes.

**Ce que la porte ferme, et ce qu'elle ne ferme pas.** Elle protège contre un
orchestrateur qui néglige, pas contre un qui triche à uid égal : ce qu'elle
exige est que la preuve vienne du CLI, recalculée depuis sa sortie brute
(`modelUsage` relu dans le `.brut`, `turn_context` relu dans le rollout que
l'artefact nomme). Fermer la classe adversariale (`role.sh` sous un uid
distinct, artefacts signés) est une décision de T2 ; le cycle de vie de
`.omc/turn/<issue>/` (remise à zéro, levée d'une faille après arbitrage, N par
tour ou par carte) aussi.

**La trace dans la PR** : un commentaire de livraison par carte — ce qui a été
fait, ce qui a été vérifié, les captures, le plan cité, et **une ligne par
relecteur** (« Opus 5 : 3 remarques, 3 corrigées »). Le rapport complet reste
dans les logs de la machine. Cette ligne est ce qui éclaire une mauvaise
direction ou un problème structurel avant qu'il coûte.

**Les captures** : prises par Pony dans son worktree pour toute carte UI (le
navigateur de test y tourne déjà), et à la demande via EVA sur la preview.
L'API GitHub n'accepte pas d'image dans un commentaire avec un jeton d'App
(`gh … --attach` exige un jeton utilisateur) : les PNG sont poussés sur une
branche orpheline `screenshots` (`<pr>/<carte>/…`) et inlinés par URL brute.
10 Mo par image.

## 5. EVA

**`gpt-6-astra` sur l'abonnement Codex** — une autre famille que l'orchestrateur
: deux familles qui se regardent valent mieux qu'une qui se relit.

**Dans la PR**, EVA transforme les remarques de l'humain — et celles du client
— en **cartes** sous la feature. Pony ne réagit jamais à un commentaire brut :
il exécute une carte qu'EVA a rédigée. Une remarque devient « #281, livrée dans
le commit X », pas un fil perdu. EVA répond aux questions produit.

**Gardienne des décisions.** Dès qu'une décision apparaît (une carte
`needs-human`, une refacto au-dessus du seuil, un désaccord de relecture, une
question de cadrage), EVA ping l'humain et **l'interviewe** en DM Slack,
question par question, avec sa recommandation. **Relance toutes les 4 h, jamais
avant 8 h ni après 21 h (Europe/Paris)** — c'est la règle d'EVA, pas le *Ne pas
déranger* de Slack, qui ne fait que taire un téléphone pendant que l'horloge
tourne. La décision prise est **écrite en commentaire sur l'issue de décision**,
l'issue fermée, et si une règle change, une carte « mettre la spec à jour »
naît sous la feature. Pony lit les dépendances ; l'humain dans six mois lit le
commentaire ; c'est le même endroit.

**Les pings.** En direct, pour ce qui *attend* l'humain : un lot livré à relire
(lien PR, captures), une carte `needs-human`, une PR d'ajustement client, la
file vide *et pourquoi*, un agent en échec répété. En réponse dans le fil Slack
pour ce qu'il a demandé : preview montée, production déployée. Pas de digest,
sauf demande. L'humain relit **par lot**, au fil de l'eau — jamais une feature
de cinquante-huit commits d'un coup.

**Ce qu'EVA ne fait toujours pas** : écrire du code, pousser sur `feature/*`,
démarrer la boucle, agir sans ordre d'un utilisateur autorisé. Son SOUL est à
réécrire pour dire ce qu'elle *fait* désormais (merger, sortir une version)
autant que ce qu'elle ne fait pas.

## 6. Ce que le dépôt consommateur fournit

- **`VERIFY.md`** (existant) : ce que « vérifié » veut dire ; la garde du commit
  direct.
- **`DOCS.md`** (nouveau, facultatif) : où vit la documentation publique,
  comment on la construit, le ton, la langue, où une page neuve se range.
  Absent → pas d'étape writer, et la boucle le dit une fois. Deviner sur la
  présence d'un `docs/` se tromperait dès le premier projet qui en a un privé.
- **Les seeders** qui remplissent la base d'une preview.
- **Les hooks** : `worktree-up` crée la base de la PR et la seed ;
  `preview-up`/`preview-down` (nouveaux) exposent et retirent le serveur du
  worktree derrière le proxy.
- **`factory.conf`** : `FACTORY_STAGING` garde son sens ; s'ajoutent le préfixe
  des branches de feature, le seuil de refacto, N, le catalogue des rôles et
  leurs modèles (avec les défauts de ce document), les heures calmes d'EVA.

## 7. Migration — Paris Showroom

- `staging` porte 39 commits que `main` n'a pas : 15 cartes CRM non relues, la
  migration de l'usine, et divers (#146–#149, #214, #215, #217, #31). **On
  l'assume** : l'humain relit une PR `staging` → `main` commit par commit, EVA
  sort une version, `staging` redevient propre. Rejouer les 15 commits sur une
  branche de feature ne raccourcirait pas la relecture et ajouterait un rebase.
- Les 24 cartes CRM restantes deviennent sous-issues d'une issue **Feature
  CRM** à créer — distincte de la map #220 —, dépendances natives conservées,
  et repartent en `feature/crm` depuis `staging` propre.
- La boucle reste **arrêtée** (marqueur `/etc/factory-loop.paused`) jusqu'à ce
  que la v2 tourne : la v1 ferait exactement ce que ce document interdit.

## 8. Décisions prises sans question

Trois choses de plomberie, tranchées pour ne pas les rediscuter — à contester
si l'une gêne :

- La preview est adressée **par port** (`http://<machine>:<port>`, un port par
  PR, alloué par le hook) : le réseau n'a pas de DNS wildcard.
- La PR de feature est créée par Pony quand il admet la première carte d'une
  feature : brouillon, puis prête à la première carte livrée.
- Un budget (durée, coût) par tour, comme garde-fou ; la valeur se fixe à
  l'implémentation, sur mesure.
- Les artefacts du tour vivent sous `.omc/turn/<issue>/` — le répertoire
  d'orchestration que `.gitignore` exclut déjà — et non sous un `.factory/`
  neuf : un seul endroit ignoré, pas deux.

## Vérifié le 18 septembre 2026, avant la première ligne

- **Types d'issue** : `Task`, `Bug`, `Feature` sont actifs sur l'organisation
  `Paris-Showroom` en plan gratuit (GraphQL `organization.issueTypes` les rend
  avec leurs ids). Le fallback label n'est pas nécessaire.
- **Modèles depuis le conteneur** (`psr-factory:dev`, homes montés) :
  `codex exec -m gpt-6-astra` répond sous le login ChatGPT — avec
  `--skip-git-repo-check` hors d'un dépôt de confiance ; `claude -p --model
  claude-opus-5` et `claude-fable-5-1` répondent sous le login claude.ai.
- **Preuve du modèle** : Claude l'écrit dans `--output-format json`
  (`modelUsage`, une entrée par modèle réellement appelé). Codex ne le met pas
  dans son flux `--json` ; son rollout `~/.codex/sessions/<date>/rollout-*.jsonl`
  porte `"model":"gpt-6-astra"` dans chaque `turn_context`, écrit par le CLI —
  on le retrouve par le `thread_id` de `thread.started`. Les deux artefacts sont
  donc **produits par le CLI**, pas par l'agent.
- **DNS** : pas de wildcard sur le réseau (`pr-1.psr-factory.lan` NXDOMAIN) :
  les previews sont adressées **par port**.

## Reste à vérifier, sans bloquer

- Le **groupement par issue parente en vue roadmap** de Projects v2 (confirmé
  en vue table seulement).
- Le point d'upload d'images non documenté de GitHub accepte-t-il un jeton
  d'App ? Non confirmé ; la branche orpheline est le chemin sûr.
- Le comportement natif de fermeture parent/sous-issues (rien n'est
  automatique d'après la doc — c'est `gh-release.sh` qui ferme la feature).

## Sources

- Sous-issues : <https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues>
- Retrait des tasklists : <https://github.blog/changelog/2025-02-18-github-issues-projects-february-18th-update/>
- Champs « Parent issue » et « Sub-issue progress » : <https://docs.github.com/en/issues/planning-and-tracking-with-projects/understanding-fields/about-parent-issue-and-sub-issue-progress-fields>
- Types d'issue : <https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/managing-issue-types-in-an-organization>
- Dépendances : <https://docs.github.com/en/rest/issues/issue-dependencies>
- Projects v2 par API : <https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects>
- `gh --attach` : <https://github.blog/changelog/2026-09-01-github-cli-media-in-issues-pull-requests-and-comments/>
- Previews Laravel Cloud (écartées : le client a `staging`, la preview reste sur la machine) : <https://laravel.com/cloud/docs/preview-environments>
