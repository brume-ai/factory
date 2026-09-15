# Le modèle de release

Un seul modèle, une seule procédure, une seule porte :

```
carte → PR → merge automatique dans la branche de TRAVAIL → … → release → branche de PRODUCTION + tag
```

**L'acceptation d'une PR a cessé d'être l'acte final. C'est la sortie d'une
release qui l'est.** Ce document dit pourquoi, ce que le modèle gouverne, ce
qu'il exige du dépôt qui l'installe, et ce qu'il ne résout pas.

## Le fait qui rend ce document nécessaire

Trois douleurs distinctes, qui se révèlent être la même.

**La cascade de conflits.** Dix cartes donnent dix PR posées sur la même base.
Le merge de la première met les neuf autres en retard, et une partie en conflit.
Il faut alors repasser un agent sur chacune — puis le merge de la huitième
recommence. Le coût croît comme le carré du nombre de PR ouvertes en même temps.

**Le goulot de relecture.** `gh-next-issue.sh` le dit lui-même, dans son bloc de
justification :

> livrée(s), en attente d'un merge humain — l'usine est à jour, c'est la review
> qui est le goulot

Tout l'outillage optimise l'**offre** de PR ; rien n'optimise la relecture. Une
usine dont la file de sortie n'est pas bornée et dont le consommateur est un
humain unique ne fabrique pas de la valeur, elle fabrique du **stock**. Et le
stock n'est pas neutre : il vieillit, il conflicte, il consomme des tours
d'entretien qui ne produisent rien de neuf. **La cascade de conflits EST le coût
du stock.**

**Les deux modes de livraison.** Une clé de configuration en gouvernait deux,
parce qu'un dépôt sans protection de branche ne pouvait pas exécuter le mode à
PR : sans exigence d'approbation, rien n'empêche le bot de merger sa propre PR,
et la garantie retombe au rang de consigne. Sept conséquences réparties sur cinq
scripts partagés, un skill dédoublé en onze paires de volets, deux suites de
tests pour prouver qu'une clé gouverne sept choses. C'était la chose la plus
chère du dépôt.

## La décision

Les trois douleurs se dissolvent dans le même geste.

**Les conflits disparaissent d'eux-mêmes.** Deux PR ne peuvent conflicter que si
elles sont ouvertes en même temps. Une PR qui vit deux heures — CI verte,
contrôle d'appartenance, merge automatique — ne croise personne. On ne répare
plus la cascade : on supprime la fenêtre où elle se forme.

**Le goulot se transforme au lieu de se déplacer.** Relire un ensemble cohérent
qui tourne devant soi coûte beaucoup moins que dix diffs disjoints avec dix
changements de contexte.

**Le mode de livraison devient sans objet.** Dans ce modèle la PR n'est plus une
porte de relecture : c'est une **unité d'intégration et un point de passage CI**.
Elle est donc utile même là où la protection de branche n'existe pas sur la
branche de travail — ce qui dissout la raison d'être du second mode. La clé, ses
deux fonctions de lecture dans `bin/lib.sh`, tous les branchements par mode et
les deux suites de tests qui les prouvaient ont été **supprimés**, sans pont ni
repli : les consommateurs sont protégés par l'épinglage de version et montent
quand ils sont prêts (voir « Migrer », plus bas).

## Les deux branches, et le piège qu'elles tendent

| Clé | Rôle | Qui y écrit |
|---|---|---|
| `FACTORY_TRUNK` (défaut `main`) | la branche de **PRODUCTION**, cible de la release | **jamais l'usine** — un humain, protégée par la forge |
| `FACTORY_STAGING` (défaut `staging`) | la branche de **TRAVAIL**, la seule où l'usine a le droit d'écrire | l'usine : les cartes en partent, les PR y retournent, l'environnement en ligne la suit |

**LE PIÈGE, ET IL A COÛTÉ LE PLUS CHER DU CHANTIER.** `FACTORY_TRUNK` désignait
avant ce modèle la branche de **travail** dans plusieurs scripts — la base par
défaut de `gh-stack.sh`, le `reset --hard` de `deploy.sh`, la garde de branche et
le `merge --ff-only` de `factory.mk`, la reprise de `wt-resume.sh`. Toute
occurrence non basculée vers `FACTORY_STAGING` est un **chemin d'écriture vers la
production**, et trois d'entre elles sont des gestes destructifs. Ça ne se voit
pas à la lecture d'un diff : ça se vérifie occurrence par occurrence, et
`tests/` le tient désormais mécaniquement (voir « Vérification »).

## Où passe la garantie

C'est le point qui décide si le modèle tient.

Avant : **N portes**, une approbation humaine par PR.
Maintenant : **une porte par release**, sur la branche de production protégée,
que le jeton d'usine ne peut pas franchir.

**Ce n'est pas une garantie plus faible — c'est la même serrure, posée là où elle
porte réellement** : à l'entrée de ce qui part en production. Ce qui entre dans
la branche de travail n'a jamais eu besoin d'être gardé ; la branche de travail
est un **terrain de preuve**, pas une destination. Une approbation par PR
prouvait « quelqu'un a regardé ce diff » ; la porte de release prouve « quelqu'un
a regardé ce qui sort », ce qui est l'énoncé dont on avait besoin.

**LA CONDITION QUI REND CETTE ÉQUIVALENCE VRAIE, ET SANS LAQUELLE ELLE EST
FAUSSE.** Si la branche de travail n'est regardée qu'au moment de la release, on
n'a pas déplacé la serrure, on a construit un accumulateur de stock et une
intégration big-bang : une release de quarante cartes est un problème de
relecture *pire* que dix PR, parce que personne ne relit quarante cartes d'un
coup. Deux conséquences à assumer, et elles ne sont pas facultatives :

- **des releases courtes** — des jours, pas des semaines ;
- **la relecture au fil de l'eau**, sur l'environnement en ligne qui suit la
  branche de travail. La release devient alors la *confirmation* de choses déjà
  vues.

Le plafond utile n'est plus « PR ouvertes » mais **« cartes intégrées non
relues »** : s'il gonfle, c'est le signal de ralentir, pas d'ouvrir un front de
plus.

**CE N'EST PAS LE JETON QUI PROTÈGE, C'EST LA PROTECTION DE BRANCHE.** Les
permissions d'une App GitHub sont à l'échelle du **dépôt**, pas de la branche :
`contents: write` autorise à écrire partout, branche de production comprise. La
garantie repose donc sur une seule chose, et elle est chez le consommateur : la
branche de production est protégée et le jeton d'usine ne peut pas la merger. Si
elle saute, plus rien ne tient — et rien dans l'usine ne peut la remplacer.

L'usine tient le peu qu'elle peut tenir : `branches_require` (`bin/lib.sh`)
**refuse de démarrer** en code 3 si `FACTORY_TRUNK` et `FACTORY_STAGING` sont la
même branche, et son message **nomme la protection de branche** au lieu de
laisser croire que le jeton suffirait. Deux branches égales, ce serait une usine
qui publie en production à chaque carte, avec une file de relecture qui n'a plus
rien à relire.

## Le cycle de vie d'une carte

| État | Label | Qui le pose |
|---|---|---|
| disponible | *aucun* | le défaut — **la file est opt-out** |
| prise | `factory:in-progress` | l'agent |
| en PR, CI en cours | `factory:delivered` | l'agent |
| **intégrée à la branche de travail, attend la release** | **`factory:staged`** | **`gh-stage-pr.sh`, au merge** |
| livrée | issue **fermée** | **`gh-release.sh`, après le tag** |

**La file de relecture humaine, c'est la liste des cartes `factory:staged` du
jalon en cours.** C'est le seul endroit où elle est écrite.

Quatre labels restent en dehors de ce cycle, parce qu'ils ne disent pas où en est
le travail mais ce qu'on en fait : `factory:blocked` (une autre carte d'abord),
`factory:needs-human` (arbitrage, hors file), `factory:epic` (un fil, pas du
travail) et `factory:priority` (passe devant). **Les sept noms sont lus à un seul
endroit** — `label_get`, dans `bin/lib.sh`, et le triage de sécurité, qui est en
Python, les reçoit résolus de son appelant — et le défaut de chacun n'a qu'un
domicile : deux copies d'un nom finissent par diverger, et un nom de label qui
diverge sort une carte de la file pour toujours, le script qui pose et celui qui
retire ne parlant plus du même mot.

## Ce que le modèle gouverne

### 1. L'intégration — `gh-stage-pr.sh`

À chaque tour de ménage, et **en premier** parce que tout le reste lit ce qu'il
produit : les PR de cartes qui ont tout prouvé sont mergées en squash dans la
branche de travail, et la carte reçoit `factory:staged`. C'est le seul geste du
dépôt qui écrit sur une branche partagée, donc le seul qui soit gardé deux fois —
la liste sert à **cadrer**, chaque PR retenue est **relue** juste avant le `PUT` :

- **L'APPARTENANCE, avant tout autre test.** La tête d'une PR de fork porte le
  nom de branche **chez le fork** : n'importe qui peut pousser `card/99` sur son
  fork et ouvrir une PR. Elle n'aurait aucun label (un extérieur ne peut pas en
  poser), sa CI passerait au vert, et l'unique porte de relecture du modèle
  serait contournée depuis l'extérieur. On exige `head.repo.full_name` égal au
  dépôt lui-même — et on refuse une tête sans dépôt, cas du fork supprimé.
- **LA BASE.** Un filtre côté serveur est une commodité, pas une preuve : un
  paramètre vide ou mal orthographié est ignoré par GitHub, qui rend alors la
  liste entière sans le dire. La base relue doit être la branche de travail ;
  une PR qui vise la production est refusée — c'est la release qui l'ouvre et la
  ferme.
- **L'ARBITRAGE HUMAIN et le BROUILLON.** Une PR qui porte
  `factory:needs-human`, ou que l'agent n'a pas déclarée prête, n'est pas
  intégrée : la merger l'enterrerait dans la branche de travail, où plus rien ne
  la distingue.
- **LA CARTE, pas seulement la PR.** Fermée à la main, ou portant
  `factory:needs-human` — c'est sur la carte que le skill fait poser
  l'arbitrage — la proposition n'est pas intégrée.
- **UN MOT DU RELECTEUR SANS RÉPONSE.** L'intégration passe AVANT l'entretien
  dans le tour ; un mot posé sur la proposition pendant sa CI serait mergé sous
  les pieds de `gh-pr-attention.sh`, qui ne carve que l'après-merge. Le login
  de confiance a le dernier mot : on attend que l'usine ait répondu.
- **`mergeable` STRICTEMENT `true`.** `null` veut dire que GitHub n'a pas fini
  de calculer, pas « oui » : on relit trois fois à trois secondes, puis on
  attend le tour suivant.
- **LA CI, et l'absence de CI est un REFUS.** C'est la seule chose qui ait vu ce
  code tourner. Le verdict est une **liste blanche** — `success`, `neutral`,
  `skipped` — écrite une fois dans `bin/lib.sh` et lue par l'intégration et
  l'entretien : `cancelled`, `timed_out`, `action_required`, `stale` sont rouges,
  pas verts. Rouge : `gh-pr-attention.sh` enverra un agent la réparer. En
  cours : au tour où elle conclura. **Aucun contrôle**, ou tous ignorés :
  refusé aussi, et dit à chaque tour — on ne peut pas distinguer « ce dépôt n'a
  pas de CI » de « les runs ne sont pas encore enregistrés », et traiter
  l'absence comme un feu vert mergerait tôt ou tard un travail dont rien n'a
  jamais tourné. Plus de cent contrôles : la page est incomplète, on ne juge pas.
- **LE `sha` VOYAGE AVEC LE MERGE.** La CI a été jugée sur une tête ; c'est
  cette tête que GitHub merge, ou 409 si elle a bougé entre-temps.

Le merge est un **squash**, et le message est composé par l'usine :
`Refs #<carte>`. Le lien carte↔commit ne dépend donc pas de ce qu'un agent a
bien voulu écrire dans les siens — c'est ce que la release relira.

La branche `card/<n>` est **supprimée** après le merge : les consommateurs ont
`delete_branch_on_merge` à false, et une proposition posée DESSUS (une couche
de pile) garderait sinon une base que plus aucune file ne liste — GitHub la
rebase lui-même sur la branche de travail quand la base disparaît.

Puis `factory:staged` est posé **avant** que `factory:delivered` soit retiré :
dans l'ordre inverse, un échec entre les deux laisserait la carte sans aucun
label, et la file étant opt-out elle repartirait à un agent neuf qui referait un
travail déjà intégré.

**Le script dit pourquoi il écarte, à chaque tour et pour chaque PR.** Une PR non
intégrée sans motif, c'est une carte qui n'avance plus et dont personne ne sait
pourquoi ; le silence coûte plus cher que le refus, parce qu'il ne se
diagnostique qu'en relisant le code. Rien sur stdout — c'est du ménage, pas un
sondage — et jamais le code 1 : « aucune PR à intégrer » n'est pas « rien à
faire ».

### 2. La release — `gh-release.sh`

**LA RELEASE SE FERME APRÈS LE GESTE HUMAIN, ELLE NE L'ANNONCE PAS.** Le script
ne pousse pas, ne merge pas, ne tague pas : il **lit**, commente et ferme. Un
script de release qui mergerait supprimerait la seule serrure du dispositif.

L'ordre est donc, et il n'est pas négociable :

1. l'humain merge la branche de travail dans la branche de production, et
   **tague** ;
2. puis `make factory-release` — qui **liste sans rien écrire** —, et
   `bash tools/factory/bin/gh-release.sh --apply` quand la liste est la bonne.

**À BLANC PAR DÉFAUT**, et c'est délibéré : ce script ferme des cartes que
personne ne rouvrira à sa place, donc il doit être impossible de le déclencher
par accident, un copier-coller ou une complétion de shell. La liste est la même
dans les deux modes — deux sorties différentes rendraient le mode à blanc inutile.

Le script n'accepte **aucun argument de version** : il la dérive. `V` est le
tag **le plus récemment créé parmi ceux que `origin/$FACTORY_TRUNK` contient**
(pas le plus proche dans le graphe : un `rc` ou un `latest` posé sur la branche
de travail n'est pas sorti et ne compte pas), lu **après un fetch** — un dépôt
local en retard nommerait la version précédente et fermerait les cartes de la
release d'avant, avec un numéro faux. Il refuse en 3 s'il n'y a aucun tag (« la release
se FERME après le geste humain, elle ne l'annonce pas ») et en 3 si `V` n'est pas
dans la branche de production (« rien n'est sorti, aucune carte n'est fermée »).
La plage est « tag précédent `..` V », à défaut toute l'histoire jusqu'à `V`, en
le disant.

**Les cartes sont déterminées par les COMMITS, et fermées explicitement.** Le
script relit les messages de la plage et n'y retient que des références
**ancrées** — `Refs #12`, et les mots-clés de fermeture pour les dépôts qui les
écrivent encore. Jamais un `#N` nu : le squash de GitHub colle le numéro de la
**pull request** au titre (« un titre (#34) »), et pris pour une carte il ferait
fermer une PR, puisque l'endpoint `/issues` ne fait pas la différence.

Chaque carte est relue avant d'être touchée — elle existe, c'est une carte et pas
une PR, elle est encore ouverte —, **commentée d'abord** puis fermée : une carte
fermée sans trace ne dit plus de quelle version elle est sortie, et c'est
irrattrapable ; un commentaire posé deux fois se relit sans dommage.
`factory:staged` est retiré au passage. Rejoué, le script ne trouve plus de carte
ouverte : il est **idempotent**.

### 3. La release est un geste HUMAIN, et c'est exécutable

La boucle exporte `FACTORY_IN_LOOP=1`, et `gh-release.sh` **refuse de tourner**
en code 3 quand ce marqueur est posé. Sans lui, l'énoncé « la boucle ne déclenche
jamais la release » ne serait qu'une phrase de documentation : la boucle exporte
`GH_TOKEN` avant de lancer l'agent en `--dangerously-skip-permissions`, donc un
agent qui explore `bin/` hérite de tout ce qu'il faut pour fermer des cartes que
personne n'a relues. Le skill l'inscrit aussi dans sa liste `<Never>`, mais une
consigne dans un prompt n'est pas une garde.

### 4. Le jalon nomme la release, et c'est le SONDAGE qui le fait respecter

`FACTORY_MILESTONE` est lue par `gh-next-issue.sh` **et par personne d'autre**.
Le filtrage est **côté client**, sur le champ `milestone` déjà présent dans la
réponse `/issues` : zéro appel de plus, zéro permission neuve, et les cartes hors
jalon restent visibles du bloc de justification.

Scinder une release coûte selon le **moment** où on le demande : une carte pas
encore intégrée sort de la file d'un clic (on la déplace vers le jalon suivant) ;
une carte déjà intégrée demande un revert, avec ses interdépendances. D'où le
choix de faire respecter le jalon au sondage, et pas à la release.

**Vide signifie AUCUN FILTRE, pas « jalon sans nom ».** Sans jalon configuré, le
sondage est inerte au byte près : mêmes appels, même carte servie.

### 5. La parole du relecteur — `gh-pr-attention.sh`

Un seul script, un seul balayage, **deux sorties selon l'état de la proposition**.

**Sur une PR ouverte**, il la réveille : la boucle envoie un agent avec le grief
précis. Son périmètre est explicite — les PR ouvertes **sur la branche de
travail**, dont la tête est une `card/<n>` **du dépôt lui-même**. C'est une
garde, pas un détail d'optimisation : le modèle crée une proposition permanente
que l'ancien n'avait pas, la **PR de release** (branche de travail →
production). Un commentaire humain dessus, c'est la discussion normale d'une
release ; sans périmètre, il enverrait un agent
`--dangerously-skip-permissions` « remettre en état, ou fermer » la seule
proposition du dépôt qui touche la production.

**Sur une PR déjà intégrée, il CARVE.** On ne rouvre jamais une PR mergée : ses
commits sont dans la branche de travail, et la rouvrir serait un nœud de rebase
pour rien. Une carte neuve est créée, liée à l'originale, portant le label de
priorité et le texte du commentaire comme grief. La boucle la prend au tour
suivant par le chemin normal : aucun mécanisme nouveau, aucun prompt nouveau. Le
mot doit être **postérieur au merge** — un « LGTM » laissé le jour du merge a
déjà eu son tour sur la surface ouverte.

**L'accusé de réception est la pièce qui empêche la panne la plus coûteuse du
modèle.** Le script répond « carvée en #M » sous le login du bot, et c'est ce qui
rend le commentaire *traité*. Sans lui, chaque tour carverait une carte NEUVE sur
le même commentaire — donc un sujet différent à chaque tour — et la garde
anti-tourniquet de `factory.mk`, qui compte les répétitions d'un **même** sujet,
ne verrait rien passer. L'accusé est posé **après** le carve : s'il rate, le tour
suivant produit un doublon visible qu'un humain ferme, là où l'ordre inverse
perdrait le retour du relecteur en silence.

**Un seul appel pour tout le dépôt, et c'est délibéré.** Relire les commentaires
PR par PR coûtait trois requêtes par PR ; sur une fenêtre récente pleine de PR
mergées — ce qu'elle est dans ce modèle — cela fait de l'ordre de cent requêtes
par tour, pour un budget d'installation d'App de 5 000 par heure et un tour par
minute à file vide. Le plafond atteint rend 403, classé en 3, et la boucle
s'arrête sur « configuration cassée » : **le balayage censé rattraper un
commentaire arrêterait l'usine.** L'endpoint dépôt-entier rend les commentaires
de conversation de toutes les issues **et** de toutes les PR — une PR *est* une
issue.

**Pour reprendre le travail d'une carte déjà sortie, rouvrez la carte.** La file
est opt-out : une issue rouverte *est* du travail, elle repart au tour suivant
sans une ligne de code, avec le commentaire du relecteur déjà dans son fil. Un
commentaire posé sur une carte fermée **sans** la rouvrir n'est lu par personne —
c'était déjà vrai avant ce modèle, et cette phrase est là pour que ça ne
surprenne plus.

## Ce que le modèle exige du consommateur

Un modèle qui déplace la garantie doit dire ce qu'il exige en échange, sinon il
offre un contrôle que personne ne tient.

1. **Deux branches distinctes**, et la branche de travail **existe** sur le
   distant. La garde refuse de démarrer si elles sont égales ; elle ne peut pas
   créer la branche qui manque.
2. **La branche de production est protégée, et le jeton d'usine ne peut pas la
   merger.** C'est la seule exigence de forge du modèle — et la seule chose qui
   protège la production. Gratuite sur dépôt public chez GitHub, gratuite chez
   Forgejo.
3. **L'environnement en ligne suit la branche de travail.** C'est lui qui rend la
   relecture au fil de l'eau possible, donc lui qui rend la porte unique
   équivalente aux N portes. Sans lui, le modèle est un accumulateur.
4. **La CI tourne sur les PR de cartes.** C'est le seul feu vert de
   l'intégration automatique : **un dépôt sans CI ne peut pas l'utiliser**, et le
   ménage le dit à chaque tour plutôt que de le laisser découvrir des semaines
   plus tard.
5. **Le dépôt autorise le merge par squash.** C'est la seule méthode utilisée, et
   c'est elle qui pose le `Refs #<carte>` que la release relira. Un dépôt qui
   l'interdit fait répondre 405 à chaque tentative, et rien ne s'intègre.
6. **Un merge fait à la main dans la branche de travail nomme sa carte**
   (`Refs #<n>`). L'intégration automatique l'écrit pour vous ; elle ne peut pas
   le faire à votre place quand vous mergez vous-même, et la release ne voit que
   ce qui est écrit dans les commits.
7. **La release est un geste humain** : merge, tag, puis la lecture à blanc, puis
   `--apply`. Dans cet ordre. **Et le merge est un merge commit ou une avance
   rapide, jamais un squash** : `gh-release.sh` relit les `Refs #n` des COMMITS
   de la plage, et un squash de la PR de release les remplacerait par un seul
   message — la release fermerait zéro carte. (« Squash and merge » est ce que
   l'usine fait sur les PR de carte ; sur la PR de release, c'est l'inverse.)
8. **L'App porte les permissions que le modèle lit et écrit** : `Contents:
   Read and write` (le merge, la suppression de la branche de carte), `Pull
   requests: Read and write`, `Issues: Read and write`, `Checks: Read` (les
   contrôles d'une PR — sur un dépôt privé, sans elle, `check-runs` rend 403 et
   rien ne s'intègre), et `Metadata: Read`. Le triage de sécurité ajoute
   `Dependabot alerts: Read`, `Code scanning alerts: Read`, `Secret scanning
   alerts: Read` ; une surface sans permission est laissée de côté, elle ne
   ferme rien.
9. **La branche par défaut du dépôt est la production, ou alors on le sait.**
   GitHub honore les mots-clés de fermeture (`Closes`, `Fixes`, `Resolves`)
   sur la branche par DÉFAUT : chez un consommateur dont la branche par défaut
   est la branche de TRAVAIL, un `Fixes #n` écrit dans un corps de PR fermerait
   la carte à l'intégration, avant toute release. Le skill interdit ces trois
   mots ; sur un tel dépôt, l'interdiction porte vraiment.
10. **Un jalon par release**, si l'on veut pouvoir en scinder une. Facultatif :
    sans jalon, tout ce qui est ouvert est dans la file.

## Ce que le modèle ne résout pas

- **La protection de branche n'est pas vérifiée par l'usine.** La garde compare
  deux noms ; elle ne demande pas à la forge si la branche de production est
  réellement protégée. Une usine correctement configurée dont la protection
  aurait sauté fonctionnerait exactement pareil — et plus rien ne tiendrait.
  C'est le métier de `factory doctor`, qui n'existe pas encore (`EVOL.md`).
- **La pagination, partout sauf au sondage.** `gh-next-issue.sh` suit l'en-tête
  `Link` sur la liste des cartes — la tête de la file ne tombe plus. Les autres
  listes (PR ouvertes, commentaires du dépôt, PR de toutes sortes pour le
  ménage) restent bornées à cent ; `EVOL.md` le garde.
- **Les PR de fork ne sont écartées qu'à l'intégration.** `gh-next-issue.sh`
  reconnaît encore une tête `card/<n>` sans regarder de quel dépôt elle vient ;
  il ne merge rien, donc le trou n'est pas exploitable, mais il est là.
- **Une review formelle sur une PR déjà mergée n'est pas vue.** Le rattrapage
  lit les commentaires de conversation du dépôt en un seul appel ; il n'existe
  pas d'endpoint équivalent pour les reviews. C'est le prix assumé d'un balayage
  qui coûte une requête par tour au lieu d'une centaine — un script de rattrapage
  qui épuiserait le quota d'API arrêterait l'usine qu'il devait aider.
- **Les branches de release** (patcher une version passée pendant que la suivante
  avance) : classe de complexité entière — cherry-picks, double maintenance — et
  rien de ce qui est décrit ici ne la réclame.
- **Ce qui tourne sur l'environnement en ligne** reste chez le consommateur :
  l'usine ne sait pas ce qu'est « la preprod ».

## Migrer depuis les deux modes de livraison

**Rupture assumée, aucun pont.** Il n'y a ni valeur de compatibilité, ni
avertissement de dépréciation : une clé disparue est disparue.

- **La clé qui choisissait le mode de livraison n'est plus lue nulle part.** La
  laisser dans un `factory.conf` n'a aucun effet et ne dit rien : elle est
  inerte, pas dépréciée. Son nom ne figure plus **nulle part** dans le dépôt —
  `git log` le garde, et c'est le seul endroit où il ait encore un sens. Un nom
  de clé supprimée qui survivrait dans la documentation finirait recopié dans un
  `factory.conf` neuf, où il ne ferait rien que personne ne verrait.
- `FACTORY_TRUNK` **a changé de sens** : elle désignait la branche de travail
  dans la plupart de ses lecteurs, elle désigne maintenant la **production**.
  C'est le seul point de la migration qui peut faire mal, et il est le seul à
  relire deux fois. Rien ne démarre en silence pour autant, et c'est ce qui rend
  la rupture tenable : une usine dont la clé nommait une branche de travail
  appelée `staging` tombe sur la garde des deux branches (code 3, avec le
  message qui nomme la protection de branche) ; une autre, restée sur `main`,
  voit la boucle refuser de partir en 5 — « l'arbre est sur main, pas sur la
  branche de travail ». Posez `FACTORY_STAGING`, créez la branche, protégez
  `FACTORY_TRUNK`.
- Un dépôt qui tournait en mode `trunk` doit se doter d'une branche de travail,
  d'une protection de branche sur sa production, et laisser la release fermer les
  cartes à la place de son pipeline.
- Le document qui décrivait les deux modes a été supprimé : son sujet n'existe
  plus. Celui-ci le remplace.

## Vérification

Un modèle ne se prouve pas en lisant le code : il se prouve en montrant que les
gestes dangereux sont refusés, hors ligne, par la suite.

```bash
bash tests/run.sh          # hors ligne, sans réseau ni dépendance
```

Ce que la suite tient, et qu'il ne faut pas laisser s'affaiblir :

- **Deux branches égales ⇒ code 3**, avant le premier appel HTTP — et le journal
  d'appels est **pré-créé** pour que « aucun appel » veuille dire « aucun appel »
  et pas « le script est mort avant d'écrire son journal ».
- **Une PR de fork n'est jamais mergée**, et une PR qui vise la production non
  plus : le journal ne porte aucun `PUT`.
- **Un tag absent de la branche de production ⇒ code 3**, aucune carte fermée.
- **`FACTORY_IN_LOOP` posé ⇒ code 3** : la boucle ne déclenche pas la release.
- **Le carve ne se répète pas** : la même fixture rejouée deux fois — le mot du
  relecteur, plus l'accusé de l'usine — ne produit pas un second `POST /issues`,
  et l'éteint avant le moindre appel de plus.
- **Un label renommé dans `factory.conf` est honoré** par les scripts de l'usine,
  par un chemin de lecture unique (`label_get`).
- **Les deux noms que ce chantier a supprimés ne sont nulle part**, et c'est
  `tests/hygiene.test.sh` qui le tient — sur le dépôt ENTIER, `git ls-files`,
  fichiers neufs compris, pas sur une liste de répertoires écrite à la main. Le
  lint écrit ses deux motifs avec une classe de caractères : sans ça il se
  trouverait lui-même, puisqu'il fait partie du dépôt qu'il balaie.
- **Trois surfaces ne nomment plus la branche de production**, et c'est la forme
  sous laquelle la suite le tient : `tests/gh-stack.test.sh`, `tests/wt.test.sh`
  et `tests/skill.test.sh` exigent l'absence de `FACTORY_TRUNK` dans
  `gh-stack.sh`, `wt-resume.sh` et le skill — les trois qui la nommaient avant.

Un balayage à la main complète la suite, il ne la remplace pas — et il ne rend
pas ce qu'on croit :

```bash
grep -rn 'FACTORY_TRUNK' bin/ factory.mk skill/   # 15 lignes, 2 fichiers
```

Quinze lignes : **huit dans `bin/lib.sh`, sept dans `bin/gh-release.sh`, rien
dans `factory.mk` ni dans `skill/`**. Et sur ces quinze, six seulement sont du
code — les neuf autres sont quatre commentaires et cinq messages d'erreur, qui
citent la clé sans la lire. Ce qu'il faut lire dans ce résultat n'est donc pas
un compte de lignes mais la **liste des fichiers** : deux, la garde et le
lecteur du tag, et aucun des deux n'écrit sur une branche.
