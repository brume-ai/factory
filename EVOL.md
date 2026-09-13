# Évolutions

Les chantiers décidés mais pas encore faits, et **pourquoi**. Un chantier sort
d'ici quand il est livré : ce fichier ne garde pas trace de ce qui est fait,
`git log` le fait déjà mieux.

Chaque entrée porte la même forme : le fait qui la rend nécessaire, la décision,
ce qu'elle exige, et ce qui reste à vérifier. Une décision dont le fait n'est pas
écrit se rediscute tous les mois.

**L'ordre compte.** Le chantier n°1 redéfinit ce que les autres ont à faire ; ne
pas commencer par lui reviendrait à optimiser des mécanismes qu'il supprime.

---

## 1. Le modèle de release — `staging`, puis une porte unique

### Le fait

Trois douleurs distinctes, qui se révèlent être la même.

**La cascade de conflits.** Dix cartes donnent dix PR posées sur le tronc. Le
merge de la première met les neuf autres en retard, et une partie en conflit. Il
faut alors repasser un agent sur chacune — puis le merge de la huitième
recommence. Le coût croît comme le carré du nombre de PR ouvertes simultanément.

**Le goulot de relecture.** `gh-next-issue.sh` le dit lui-même :

> livrée(s), en attente d'un merge humain — l'usine est à jour, c'est la review
> qui est le goulot

Tout le dépôt optimise l'**offre** de PR ; rien n'optimise la relecture. Une
usine dont la file de sortie n'est pas bornée et dont le consommateur est un
humain unique ne fabrique pas de la valeur, elle fabrique du stock. Et le stock
n'est pas neutre : il vieillit, il conflicte, il consomme des tours d'entretien
qui ne produisent rien de neuf. **La cascade de conflits EST le coût du stock.**

**Les deux modes de livraison.** `FACTORY_DELIVERY` existe parce que PSR n'a pas
de protection de branche, ce qui rendait la PR *« un rituel sans effet »*. Sept
conséquences réparties sur cinq scripts partagés, plus un `factory doctor` à
écrire, plus un skill à dédoubler. C'est la chose la plus chère du dépôt.

### La décision

**L'acceptation d'une PR cesse d'être l'acte final. C'est la sortie d'une
release qui l'est.**

```
carte → PR → merge automatique dans `staging` → … → release → `main` + tag
```

`staging` tourne en permanence sur un environnement dédié, accessible en ligne.
Le travail s'y accumule sous un jalon. L'humain relit **au fil de l'eau**, sur
l'environnement vivant, et décide quand sortir la version.

### Ce que ça résout, et pourquoi les trois douleurs n'en faisaient qu'une

**Les conflits disparaissent d'eux-mêmes.** Deux PR ne peuvent conflicter que si
elles sont ouvertes en même temps. Une PR qui vit deux heures — CI verte, contrôle
d'Eva, merge — ne croise personne. On ne répare plus la cascade : on supprime la
fenêtre où elle se forme. `gh-stack.sh restack` reste utile comme filet (voir
chantier 5), il devient rare.

**Le goulot se transforme au lieu de se déplacer.** Relire un ensemble cohérent
qui tourne devant soi coûte beaucoup moins que dix diffs disjoints avec dix
changements de contexte.

**`FACTORY_DELIVERY` devient supprimable.** Dans ce modèle, la PR n'est plus une
porte de relecture : c'est une **unité d'intégration et un point de passage CI**.
Elle est donc utile même sans protection de branche — ce qui dissout la raison
d'être du mode `trunk`. Les deux consommateurs convergent sur le même flux.

### Où passe la garantie

C'est le point qui décide si le design tient, et il tient.

Aujourd'hui : **N portes**, une approbation humaine par PR.
Demain : **une porte par release**, sur `main` protégée, que le bot ne peut pas
franchir.

Ce n'est pas une garantie plus faible — c'est la même serrure, posée là où elle
porte réellement : à l'entrée de ce qui part en production. Ce qui entre dans
`staging` n'a jamais eu besoin d'être gardé ; `staging` est un terrain de preuve,
pas une destination.

D'où un **énoncé d'exigence forge minuscule**, et c'est lui qui gouverne le
chantier 2 :

> La factory a besoin d'exactement une chose de sa forge : une branche `main`
> protégée que le jeton d'usine ne peut pas merger.

Rien d'autre. Ni GHAS, ni file de merge, ni piles natives. Gratuit sur dépôt
public chez GitHub, gratuit chez Forgejo, et au palier le moins cher chez GitHub
en privé. **Cette exigence-là se finance.**

**Nuance à ne pas perdre** : les permissions d'une App GitHub sont à l'échelle du
dépôt, pas de la branche. `contents: write` autorise à écrire partout, `main`
comprise. Ce n'est donc **pas le jeton** qui protège `main`, c'est la protection
de branche. Si elle saute, plus rien ne tient. C'est le même trou que celui du
chantier 3, au même endroit, et la même garde le couvre.

### Le cycle de vie d'une carte

Il manque un état, et c'est celui qu'on relit.

| État | Label | Qui le pose |
|---|---|---|
| disponible | aucun | le défaut |
| prise | `factory:in-progress` | l'agent |
| en PR, CI en cours | `factory:delivered` | l'agent |
| **intégrée à `staging`, attend la release** | **`factory:staged`** | **le merge automatique** |
| livrée | issue **fermée** | **la release** |

**La file de relecture, c'est la liste des cartes `factory:staged` du jalon en
cours.**

### Ce qui ferme une carte : écrit, jamais hérité

Piège mécanique : GitHub ne ferme les issues liées par `Closes #N` que lorsque la
PR est mergée dans la **branche par défaut**. Une PR mergée dans `staging` ne
ferme donc rien — ce qui arrange, la carte doit rester ouverte. Mais au moment de
la release, le comportement dépend de la façon dont les commits ont été squashés.
C'est fragile.

**Ne pas compter dessus.** Le script de release connaît les commits entre le
dernier tag et `staging`, donc il connaît les cartes : il les **ferme
explicitement**, avec un commentaire nommant la version. Déterministe, testable
hors ligne avec le faux `curl` existant, et — décisif pour le chantier 2 —
**portable sur n'importe quelle forge**. La magie de GitHub ne l'est pas.

### Eva

La frontière est structurelle, pas consignée :

- **Sur `staging` : autorité pleine.** Elle analyse, elle refuse, elle merge.
  Elle n'y dépense aucune garantie, parce qu'il n'y en a pas à cet endroit.
- **Sur `main` : aucune.** La release est le geste humain.

**Ses questions atterrissent dans la forge, pas dans le fil de conversation.** La
doctrine est déjà écrite dans le skill : *« La persistance vit dans les issues et
les branches, pas en mémoire. »* Une question posée seulement en conversation
meurt avec la session — et une usine sans surveillance perd des sessions. Eva
commente **la carte** et pose `factory:needs-human` ; le fil conversationnel est
une surface d'affichage et de réponse rapide, jamais le lieu de l'état.

### Reprendre le travail sur une PR déjà intégrée

**On ne rouvre pas la PR.** Ses commits sont dans `staging` ; rouvrir une branche
mergée est un nœud de rebase et de revert pour rien.

Un commentaire du login de confiance sur une PR intégrée — ou sur la carte —
**carve une carte neuve**, liée à l'originale, en `factory:priority`, portant le
texte du commentaire comme grief. La boucle la prend au tour suivant par le
chemin normal : aucun mécanisme nouveau, aucun prompt nouveau.

La moitié du code existe : `gh-pr-attention.sh` sait déjà détecter la parole du
relecteur (commit 57fafeb). Même détection, sortie différente selon que la PR est
ouverte (on la réveille) ou intégrée (on carve).

### Scinder une release

Le coût dépend entièrement du **moment** où on le demande :

- carte **pas encore dans `staging`** → gratuit, il suffit qu'elle sorte de la file ;
- carte **déjà dans `staging`** → il faut un revert, avec ses interdépendances.

D'où : **le jalon (milestone) nomme la release, et c'est le SONDAGE qui le fait
respecter, pas la release.** `gh-next-issue.sh` ne prend que les cartes du jalon
courant ; une carte d'un jalon futur est hors file — le mécanisme d'opt-out
existant, réutilisé tel quel, sans nouveau label.

« Une v1 sans x, y et z » devient : déplacer x, y, z vers le jalon suivant. Un
clic chacun, et la file obéit immédiatement. Et si l'une d'elles est **déjà
intégrée**, le script doit le **dire fort** — « #42 est déjà dans `staging`, la
sortir de v1.4 demande un revert, voici la commande » — au lieu de laisser croire
que le déplacement a suffi.

Les jalons existent chez GitHub, GitLab et Forgejo : portable.

### La release

Linéaire : merge `staging` → `main`, tag, fermeture explicite des cartes,
`staging` continue.

**Pas de branches de release** tant qu'il ne faut pas patcher une version passée
pendant que la suivante avance. C'est une classe de complexité entière
(cherry-picks, double maintenance) et rien de ce qui est décrit ici ne la
réclame.

### Le mode d'échec qui tue ce design

**Si `staging` n'est regardé qu'au moment de la release, on a construit un
accumulateur de stock et une intégration big-bang.** Une release de 40 cartes est
un problème de relecture *pire* que dix PR : le goulot aura été déplacé sans être
réduit, et on aura remis du cycle en V dans un dispositif conçu pour l'éviter.

Ce qui rend le modèle gagnant, c'est que l'environnement en ligne permet de
relire **pendant que ça atterrit**, et que la release devient la *confirmation*
de choses déjà vues. Deux conséquences à assumer :

- **Des releases courtes.** Des jours, pas des semaines.
- **Eva tient le digest** — « voilà ce qui a atterri dans `staging` depuis ta
  dernière visite ». C'est son meilleur métier ici, et il remplace le plafond de
  PR ouvertes : le plafond devient **« cartes intégrées mais non relues »**, et
  s'il gonfle, la boucle ralentit au lieu d'ouvrir un front de plus.

### À vérifier

- [ ] Que le merge automatique vers `staging` ne puisse jamais toucher `main` :
      protection de branche en place **avant** d'activer quoi que ce soit.
- [ ] Le comportement réel de fermeture d'issue au merge `staging` → `main` selon
      la stratégie de squash — pour confirmer qu'il faut bien fermer à la main.
- [ ] Ce que devient `wt-resume.sh` : avec des PR à durée de vie courte, un
      worktree par carte garde-t-il son sens ?

### Ce que ce chantier périme

- `docs/livraison.md` **entièrement**, et la clé `FACTORY_DELIVERY` avec.
- Le plafond de PR ouvertes tel qu'envisagé (remplacé par « intégrées non relues »).
- L'intérêt d'une file de merge native, et donc l'argument qui liait ce sujet à
  GitHub.

### La stratégie : rupture, pas cohabitation

Une première version de ce chantier ajoutait un TROISIÈME mode à `FACTORY_DELIVERY`,
pour ne casser ni Brume ni PSR. Écarté, et délibérément : le résultat aurait été un
dépôt plus riche là où il fallait un dépôt plus simple. **Le chantier est une
suppression avant d'être un ajout.**

`FACTORY_DELIVERY`, `delivery_mode`, `delivery_require`, tous les branchements par mode,
`docs/livraison.md`, `tests/delivery.test.sh` et `tests/delivery-make.test.sh`
disparaissent. Le skill perd ses volets par mode et redevient une procédure unique.

**Critère de réussite mesurable** : sur la machinerie de mode, le diff doit être
franchement NÉGATIF en lignes. Un chantier qui ajoute plus de conditionnel qu'il n'en
retire a raté sa cible, quoi qu'il livre par ailleurs.

Aucun pont de compatibilité, aucun repli, aucun avertissement de dépréciation : les
consommateurs sont protégés par l'épinglage de version et montent quand ils sont prêts.
PSR, qui tourne en `trunk`, devra se doter d'une branche de travail, d'une protection de
branche sur la production et d'un workflow de fermeture avant de monter.

### Les deux branches, et le piège qu'elles tendent

- `FACTORY_TRUNK` = la branche de **production**, cible de la release (défaut `main`).
  Protégée. **L'usine n'y écrit jamais.**
- `FACTORY_STAGING` = la branche de **travail** (défaut `staging`). Les cartes en
  partent, les PR y retournent, l'environnement en ligne la suit.

**LE PIÈGE, ET IL EST SÉRIEUX.** `FACTORY_TRUNK` désigne aujourd'hui la branche de
TRAVAIL dans plusieurs scripts : la garde de branche et le `merge --ff-only` de
`factory.mk`, le `reset --hard` de `deploy.sh`, la base par défaut de `gh-stack.sh`, la
référence de reprise de `wt-resume.sh`. Quatorze fichiers la mentionnent. **Toute
occurrence non basculée vers `FACTORY_STAGING` devient un chemin d'écriture vers la
production** — et trois d'entre elles sont des gestes destructifs. C'est le défaut le
plus dangereux de ce chantier, et il ne se voit pas à la lecture du diff : il faut
vérifier chaque occurrence une par une.

### Le chemin de lecture des labels vient avec

Le chantier 4 porte un « défaut connu » : six clés `FACTORY_*_LABEL` sont lues par
expansion directe de l'environnement au lieu de `conf_get`, si bien que les poser dans
`factory.conf` ne suffit pas. Ce chantier ajoute un **septième** label. Ajouter sur un
chemin cassé serait le contraire de propre : la correction est donc rapatriée ici.
Toutes les clés de label passent par `conf_get`, et le paragraphe d'avertissement de
`docs/configuration.md` disparaît avec le défaut.

La pagination, elle, reste au chantier 4 : orthogonale, elle doublerait le diff et le
rendrait irrelisable.

---

## 2. Sortir du verrou GitHub — devenu un sujet de coût, plus d'architecture

> **Réécrit après le chantier 1.** Ce chantier était le premier ; il ne l'est
> plus. Le modèle de release réduit l'exigence de forge à une ligne — *une `main`
> protégée que le bot ne peut pas merger* — donc la migration cesse d'être une
> question d'architecture pour devenir une question de facture. Elle reste à
> faire ; elle ne commande plus rien.

### Le fait

La facture GitHub dépasse 100 $/mois, sur trois lignes : **sièges**, **minutes
Actions**, **add-on Security**. Et l'usine n'a qu'une forge dans les mains :
`curl` vers `api.github.com` dans six scripts, `gh` dans le skill, les
conventions d'URL (`blob/…?raw=true`), le flux de jeton d'App, les trois surfaces
de sécurité.

### Ce qui a été tranché

**Le périmètre : les dépôts produits bougent, la factory reste sur GitHub.** Sur
un dépôt **public**, GitHub donne gratuitement protection de branche, CodeQL,
secret-scanning, Dependabot et les Actions. Le jour où ce dépôt devient public
(`tests/hygiene.test.sh` existe pour ça), il ne coûte plus rien **et** il garde
la garantie la plus forte disponible. Ce n'est pas un compromis : c'est le seul
endroit où le haut de gamme est gratuit.

**Le candidat, c'est Forgejo. Pas GitLab.** Contre-intuitif et décisif : les
règles d'approbation obligatoire de GitLab sont **Premium, y compris en CE
auto-hébergé**. Migrer vers GitLab pour économiser ferait perdre exactement la
propriété sur laquelle repose la porte de release. Forgejo n'a qu'un seul palier,
et son API est de forme GitHub (`/api/v1/repos/{owner}/{repo}/issues`) : l'écart
de portage est petit. GitLab, c'est les deux tiers du coût du multi-forge pour le
candidat qui ne rend pas la garantie — **il n'est pas au programme** tant qu'un
consommateur réel ne le demande pas.

**Deux des trois lignes se coupent sans changer de forge.**

| Ligne | Levier | Migration requise ? |
|---|---|---|
| Minutes Actions | runner auto-hébergé sur la machine déjà payée | **non** |
| Add-on Security | remplacer CodeQL + secret-scanning par du libre en CI | **non** |
| Sièges | Forgejo pour les dépôts produits | oui |

### L'ordre

1. **Runner auto-hébergé** sur la machine d'usine : la ligne « minutes » tombe à
   zéro sans toucher à l'architecture. Audit des sièges dans la foulée.

2. **Les trois faits Forgejo**, sur une instance jetable, un après-midi :
   (a) l'auteur d'une PR se voit-il proposer « Approve » ? (b) « required
   approvals » bloque-t-il réellement le merge ? (c) à quoi ressemble l'API des
   runs de CI ? Le (b) est celui qui compte vraiment : c'est la porte de release.

3. **Reconstruire le triage de sécurité sur du libre, EN RESTANT SUR GITHUB.**
   Sur Forgejo il n'existe aucune API d'alertes : les substituts (Semgrep,
   gitleaks, Renovate) sont des **jobs de CI produisant des artefacts**, pas des
   surfaces interrogeables. `gh-security-triage.py` doit donc de toute façon
   apprendre à lire des artefacts — c'est le plus gros morceau de découplage de
   forge du projet. Le faire maintenant coupe l'add-on tout de suite, s'écrit
   dans l'environnement le mieux connu avec le harnais de fixtures existant,
   laisse le temps de juger le remplaçant avant d'en dépendre, et rend la pièce
   portable le jour de la bascule.

   Au passage, ça exécute la frontière que `docs/livraison.md` appelle déjà :
   **`gh-security-triage.py` sort du cœur et devient l'implémentation de
   référence du crochet `housekeeping`.**

4. **Extraire le port de forge avec GitHub SEUL derrière.** `bin/forge/`, un
   adaptateur, les mêmes noms de fonctions, du **JSON normalisé** sur stdout.
   La règle qui décide si la couture tient : *les adaptateurs normalisent, la
   logique ne branche jamais sur la forge*. Un `if [ "$FORGE" = … ]` ailleurs que
   dans un adaptateur signale une frontière mal placée.

   Un seul adaptateur, délibérément — la règle qui a rendu `FACTORY_DELIVERY`
   légitime : on abstrait sur des copies qui ont **réellement** divergé, jamais
   sur une optionalité imaginée.

5. **Forgejo quand un dépôt réel bouge.** La deuxième implémentation est celle
   qui révèle où la frontière est fausse : ne pas figer le port avant qu'elle
   existe.

6. **Passer ce dépôt public**, dès que l'hygiène le permet.

### Ce que la migration laisse à faire

Issues, labels et PR (écart petit), URL de preuve, et **l'authentification — qui
est une régression réelle**. Le jeton d'App GitHub vit une heure, est scopé à
l'installation et n'est lié à aucun humain. Forgejo n'a pas d'équivalent : ce
sera un PAT long, sans rotation. La doctrine « jamais le jeton sur disque » tient
toujours, mais « et de toute façon il expire dans une heure » disparaît. À
décider les yeux ouverts.

### À vérifier

- [ ] **Les commits de l'App d'usine consomment-ils une licence GHAS ?** L'add-on
      est facturé **par committer actif**. Si `…[bot]` figure dans la liste des
      committers actifs de l'onglet de facturation, l'usine indexe sa propre note
      de sécurité sur son débit : la faire tourner plus fort la fait coûter plus
      cher. Défaut d'architecture économique, pas ligne de facture.
- [ ] Les trois faits Forgejo (étape 2).
- [ ] Ce que vaut Semgrep OSS face à CodeQL sur les dépôts réels — à constater
      avant de couper l'add-on, pas après.

---

## 3. La garde de `main` — et `factory doctor`

### Le fait

Le chantier 1 fait reposer **toute** la garantie sur une seule chose : `main` est
protégée et le jeton d'usine ne peut pas la merger. Les permissions d'une App
étant à l'échelle du dépôt, rien d'autre ne s'y oppose.

Le même trou existe déjà aujourd'hui, par une autre porte.
`docs/livraison.md` confie à `factory doctor` les trois exigences sans lesquelles
`FACTORY_DELIVERY=trunk` est dangereux, et désigne la troisième comme « la plus
importante, et celle qu'une clé de configuration mal comprise peut faire sauter
d'un caractère » : *le tronc de l'usine n'est pas le tronc de production*.

**`factory doctor` n'existe pas.** `bin/factory` fait `status | log | deploy |
stop | ssh`. Le mode a été livré (PR #10) avant son garde-fou. Deux lignes dans
un `factory.conf` suffisent aujourd'hui à donner à un agent non supervisé, lancé
en `--dangerously-skip-permissions`, un accès direct en écriture à la production.
Rien ne le refuse, rien ne le signale.

C'est la classe de panne que tout le reste du dépôt est construit pour empêcher :
une configuration qui a l'air de marcher.

### La décision

**Une garde en dur au démarrage de la boucle, tout de suite** : refuser de
démarrer si la branche de destination de l'usine est la branche de production, ou
si `main` n'est pas protégée. Cinq lignes, le trou est fermé aujourd'hui.

Puis `factory doctor`, qui énonce le contrat ligne par ligne et **nomme ce qui
manque**, comme le README le promet déjà.

### Dette de documentation, dans le même geste

L'en-tête de `docs/livraison.md` dit toujours « Rien de ce qu'il énonce n'est
implémenté ». C'est faux depuis la PR #10. Doc périmée dans le document qui
gouverne une clé à conséquence sécuritaire — et qui sera de toute façon réécrit
par le chantier 1.

---

## 4. Deux défauts mécaniques, indépendants du reste

- **La pagination.** Aucun script bash ne suit l'en-tête `Link` :
  `gh-next-issue.sh`, `gh-pr-attention.sh`, `gh-stack.sh`, `gh-unblock.sh` et
  `wt-cleanup.sh` posent `per_page=100` et s'arrêtent là. Au-delà de 100 issues
  ouvertes, la file perd sa traîne **en silence** — exactement le mode d'échec
  que le passage en opt-out devait tuer (« l'oubli était SILENCIEUX »),
  réintroduit par une autre porte. `gh-security-triage.py` pagine correctement :
  le raisonnement est écrit, il reste à le porter en bash.

- **Le chemin de lecture des six labels.** `docs/configuration.md` le porte déjà
  en « Défaut connu, à corriger » : six clés `FACTORY_*_LABEL` sont lues
  directement dans l'environnement du process, pas par `conf_get`. Les poser dans
  `factory.conf` ne suffit donc pas, et rien ne le dit à l'exécution. Un chemin
  de lecture, ou ça mordra — d'autant plus que le chantier 1 ajoute
  `factory:staged`.

---

## 5. `restack` sur le tronc — le filet, une fois le chantier 1 fait

### Le fait

`gh-stack.sh restack` fait déjà exactement le bon geste — fetch, `git rebase
<base> <branche>`, `--force-with-lease`, récursion, et sur conflit `rebase
--abort` + signalement. **Il n'est jamais appelé avec le tronc en argument**,
alors que `pulls?state=open&base=<tronc>` rend toutes les PR de cartes.

Un rebase qui ne conflicte pas est déterministe : il n'a pas besoin d'une
intelligence, il a besoin de `git`. Aujourd'hui chaque PR en retard coûte un tour
d'agent complet.

### La décision

Après le chantier 1, la fenêtre de conflit se referme d'elle-même et ce chantier
devient **un filet, pas une réparation**. Il garde sa valeur pour les PR à durée
de vie anormalement longue (carte reprise, CI lente, question en attente).

L'appeler avec le tronc demande trois durcissements, et aucun n'est optionnel :

1. **Il s'arrête au premier conflit** (`return 1` dans la boucle). Correct sur une
   pile — la suite dépend de la couche cassée — faux sur le tronc, où une PR qui
   conflicte empêcherait le rebase de toutes les autres, qui n'ont rien à voir
   avec elle. Il faut `continue`, collecter les échecs, sortir non-zéro à la fin
   avec la liste.

2. **Il rebase dans l'arbre courant.** `git rebase <upstream> <branche>` fait un
   checkout de `<branche>` : appelé depuis l'arbre principal, il le laisse sur une
   branche de carte — exactement ce que la garde de `make loop` refuse au
   démarrage (« la boucle tournerait avec un outillage périmé »), reproduit par la
   porte de service. Il lui faut un worktree de travail dédié, jetable.

3. **Deux catégories de PR à ne pas toucher** : celles dont la carte porte
   `factory:in-progress` (un agent tient ce worktree ; un force-push sous ses
   pieds détruit son travail non poussé), et celles déjà approuvées si la
   protection de branche écarte les approbations périmées — sinon le ménage
   annule les relectures qu'on vient de faire.

### Avant de construire quoi que ce soit : mesurer

Une PR **en retard** et une PR **en conflit** sont deux choses différentes. Si
elles conflictent réellement, c'est que des cartes indépendantes touchent les
mêmes fichiers — et c'est **ça**, le vrai défaut. Suspects par ordre de
fréquence : le **lockfile** (toute carte qui ajoute une dépendance le touche :
conflit garanti, sémantiquement trivial, et réparable sans agent par une
stratégie de merge plus une régénération), les migrations à nom séquentiel, les
fichiers-registre tenus à la main (routes, conteneur d'injection, barrel
`index`), le CHANGELOG et tout fichier généré versionné.

Donc, d'abord : **que `restack` journalise les chemins qui conflictent.** Deux
semaines de données diront probablement que l'essentiel tient dans deux fichiers
— et on corrige deux fichiers au lieu de construire un mécanisme général.

### Ce qui reste hors sujet

**Ne pas généraliser l'empilement.** Le skill dit déjà pourquoi : *« S'empiler
sans dépendance ferait afficher à votre PR le travail d'une autre, et un conflit
sur cette couche étrangère gèlerait le vôtre sans raison. »* Empiler des cartes
indépendantes ne supprime pas le travail de résolution, il le **sérialise** —
N conflits indépendants contre une chaîne unique à blocage de tête. L'empilement
est bon précisément parce qu'il est réservé aux dépendances **déclarées**.
