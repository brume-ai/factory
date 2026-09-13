# Évolutions

Les chantiers décidés mais pas encore faits, et **pourquoi**. Un chantier sort
d'ici quand il est livré : ce fichier ne garde pas trace de ce qui est fait,
`git log` le fait déjà mieux.

Chaque entrée porte la même forme : le fait qui la rend nécessaire, la décision,
ce qu'elle exige, et ce qui reste à vérifier. Une décision dont le fait n'est pas
écrit se rediscute tous les mois.

**L'ordre compte.** Le modèle de release est livré (`docs/release.md`) ; ce qui
reste commence donc par le trou qu'il laisse ouvert — toute la garantie tient
maintenant sur une protection de branche que rien ne vérifie.

---

## 1. `factory doctor` — personne ne vérifie la protection de branche

### Le fait

Le modèle de release fait reposer **toute** la garantie sur une seule chose : la
branche de production est protégée et le jeton d'usine ne peut pas la merger. Les
permissions d'une App étant à l'échelle du dépôt, rien d'autre ne s'y oppose.

**La moitié du garde-fou est posée.** `branches_require` (`bin/lib.sh`) refuse de
démarrer, en 3, quand la branche de travail et la branche de production sont la
même, et son message nomme la protection de branche au lieu de laisser croire que
le jeton suffirait. Le dépôt a déjà payé cette panne-là par une autre porte : le
mode de livraison qui pointait l'usine sur la production a été livré (PR #10)
avant le garde-fou qui devait l'encadrer, et deux lignes de `factory.conf`
donnaient alors à un agent non supervisé, lancé en
`--dangerously-skip-permissions`, un accès direct en écriture à la production.

**L'autre moitié n'existe pas, et c'est la plus importante.** La garde compare
deux NOMS. Elle ne demande pas à la forge si la branche de production est
réellement protégée, ni si l'App d'usine est réellement incapable de la merger.
Une usine dont la protection a sauté — ou n'a jamais été posée — tourne
exactement pareil : le merge automatique continue, la release continue, et rien
ne le signale. C'est la classe de panne que tout le reste du dépôt est construit
pour empêcher : une configuration qui a l'air de marcher.

**`factory doctor` n'existe toujours pas.** `bin/factory` fait `status | log |
deploy | stop | ssh`, et le README promet le docteur depuis le premier jour.

### La décision

Il énonce le contrat ligne par ligne et **nomme ce qui manque**, par ordre de
gravité :

1. **la branche de production est protégée et l'App ne peut pas la merger** —
   seule exigence de forge du modèle, et seule chose qui tienne la production ;
2. **la branche de travail existe sur le distant** — sinon rien ne démarre, et
   pas au même endroit selon d'où l'on part : le clone d'une première
   installation échoue (l'unité redémarre indéfiniment en ayant l'air
   installée), et sur un poste c'est la garde de branche qui refuse ;
3. les labels `factory:*` existent sous les noms que la configuration leur donne ;
4. le reste du contrat d'installation que le README énumère déjà.

**Un énoncé, deux appelants** : le docteur et la garde de démarrage lisent le
même contrat, sinon le docteur se périme par rapport à la boucle — et c'est le
docteur qu'on croit.

---

## 2. Sortir du verrou GitHub — devenu un sujet de coût, plus d'architecture

> **Réécrit après le modèle de release, puis relu quand il a été livré.** Ce
> chantier était le premier ; il ne l'est plus. Le modèle réduit l'exigence de
> forge à une ligne — *une branche de production protégée que le bot ne peut pas
> merger* — donc la migration cesse d'être une question d'architecture pour
> devenir une question de facture. Elle reste à faire ; elle ne commande plus
> rien.

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

   Au passage, ça exécute la frontière que le dépôt pose déjà — le triage
   d'alertes propres à un produit est de la politique, donc un crochet :
   **`gh-security-triage.py` sort du cœur et devient l'implémentation de
   référence du crochet `housekeeping`.**

4. **Extraire le port de forge avec GitHub SEUL derrière.** `bin/forge/`, un
   adaptateur, les mêmes noms de fonctions, du **JSON normalisé** sur stdout.
   La règle qui décide si la couture tient : *les adaptateurs normalisent, la
   logique ne branche jamais sur la forge*. Un `if [ "$FORGE" = … ]` ailleurs que
   dans un adaptateur signale une frontière mal placée.

   Un seul adaptateur, délibérément — la règle qui rendait légitime la clé de
   mode de livraison, aujourd'hui supprimée : on abstrait sur des copies qui ont
   **réellement** divergé, jamais sur une optionalité imaginée.

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

## 3. La pagination — la file perd sa traîne en silence

**L'autre moitié de ce chantier est faite** : le chemin de lecture des labels —
des clés `FACTORY_*_LABEL` lues directement dans l'environnement du process au
lieu de `conf_get`, si bien que les poser dans `factory.conf` ne suffisait pas —
a été rapatrié dans le modèle de release, parce qu'ajouter un septième label sur
un chemin cassé aurait été le contraire de propre. Le paragraphe « Défaut connu,
à corriger » de `docs/configuration.md` est parti avec le défaut — il y reste une
ligne, et une seule : `gh-security-triage.py`, qui ne peut pas sourcer `lib.sh`,
doit lire les noms que son appelant lui passe déjà au lieu de ses propres
défauts. Reste surtout la pagination, orthogonale à tout le reste.

Aucun script bash ne suit l'en-tête `Link` : ils posent `per_page=100` et
s'arrêtent là. Au-delà de cent issues ouvertes, la file perd sa traîne **en
silence** — exactement le mode d'échec que le passage en opt-out devait tuer
(« l'oubli était SILENCIEUX »), réintroduit par une autre porte.
`gh-security-triage.py` pagine correctement : le raisonnement est écrit, il reste
à le porter en bash.

---

## 4. `restack` sur la branche de travail — le filet

### Le fait

`gh-stack.sh restack` fait déjà exactement le bon geste — fetch, `git rebase
<base> <branche>`, `--force-with-lease`, récursion, et sur conflit `rebase
--abort` + signalement. **Il n'est jamais appelé avec la branche de
travail en argument**, alors que `pulls?state=open&base=<branche de travail>`
rend toutes les PR de cartes.

Un rebase qui ne conflicte pas est déterministe : il n'a pas besoin d'une
intelligence, il a besoin de `git`. Aujourd'hui chaque PR en retard coûte un tour
d'agent complet.

### La décision

Le modèle de release referme d'elle-même la fenêtre de conflit — une PR qui vit
deux heures ne croise personne — et ce chantier est désormais **un filet, pas une
réparation**. Il garde sa valeur pour les PR à durée
de vie anormalement longue (carte reprise, CI lente, question en attente).

L'appeler avec la branche de travail demande trois durcissements, et aucun n'est
optionnel :

1. **Il s'arrête au premier conflit** (`return 1` dans la boucle). Correct sur une
   pile — la suite dépend de la couche cassée — faux sur la branche de travail,
   où une PR qui
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
