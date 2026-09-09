# Les deux modes de livraison

> **Ce document décrit une cible.** Rien de ce qu'il énonce n'est implémenté :
> l'usine partagée ne connaît aujourd'hui qu'un seul mode, celui de Brume, et
> elle ne le sait même pas — il est tissé dans les scripts, sans nom.

## Le fait qui rend ce document nécessaire

Deux usines tournent sur le même outillage et livrent différemment.

Chez **Brume**, la boucle rend une **pull request**, fermée par le merge d'un
humain. Chez **Paris Showroom**, elle **pousse sur `staging`**, et la carte est
fermée par le **déploiement réussi** de son commit sur la preprod.

La tentation est de traiter la seconde comme une dérive de la première. C'est
faux, et c'est le point de départ de tout ce qui suit : **les deux formulent la
même exigence**, et n'en tirent des mécanismes différents que parce que l'une
dispose d'un outil que l'autre n'a pas.

L'exigence, énoncée par le skill de Brume :

> l'agent ne peut pas s'auto-approuver, non par consigne mais par construction —
> GitHub interdit d'approuver sa propre PR, et la protection de branche exige une
> approbation.

Chez PSR, la protection de branche est **indisponible** : dépôt privé, plan
gratuit, abonnement écarté. Sans exigence d'approbation, rien n'empêche le bot de
merger sa propre PR — la garantie retomberait au rang de consigne, ce que la
phrase ci-dessus existe précisément pour refuser. Conserver la PR y serait donc
un rituel sans effet.

PSR est allé chercher **un autre fait que l'agent ne contrôle pas** : le
pipeline. Une carte est fermée par le déploiement de son commit, jamais par
l'agent qui l'a travaillée.

Ce que ça prouve est plus faible — que le code compile, passe la suite et se
déploie, pas qu'il est correct — et PSR l'assume, en désignant sa suite de tests
comme le rempart réel. **Ce n'est pas le sujet ici.** Le sujet est qu'un dépôt
sans protection de branche ne peut pas exécuter le mode de Brume, et qu'il n'a
pas à forker l'usine pour autant.

## Une contradiction à trancher d'abord

Le tableau « Adapter sans forker » du README range aujourd'hui **« la façon de
livrer »** parmi la **politique**, donc parmi les crochets. Ce document dit
l'inverse : c'est une clé.

Les deux ne peuvent pas tenir, et c'est le README qui a tort — pour une raison
mécanique, pas de goût. Un crochet est un exécutable que l'usine **appelle** ; il
ne peut pas changer ce qui se passe **à l'intérieur** des scripts partagés. Or le
mode de livraison change la définition de « déjà livrée » dans
`gh-next-issue.sh`, le critère de `gh-unblock.sh`, le jeu de labels de
`gh-seed-labels.sh` et l'ordre du tour dans `factory.mk`. Aucun crochet ne
peut atteindre ces endroits sans devenir un fork déguisé.

Ce qui est bien de la politique, c'est la **surface de relecture** qu'on met en
face — la PR de promotion permanente de PSR en est une, pas la seule. La ligne du
README confond le mode et sa compensation. Elle doit devenir :

| Le besoin | La réponse |
|---|---|
| c'est de la politique — l'ordre de la file, la surface de relecture, une PR de promotion, des alertes propres au projet | un crochet dans `tools/factory-hooks/` |

## Une clé, pas un fork

```
FACTORY_DELIVERY = pull-request | trunk        # défaut : pull-request
```

`pull-request` est le défaut parce que c'est le mode qui porte la garantie la
plus forte. Un consommateur qui ne sait pas ce qu'il veut doit obtenir celui-là.

La clé se lit par `conf_get`, comme tout le reste, donc dans `factory.conf`.

## Ce que la clé gouverne — et rien de plus

Sept conséquences. Chacune est aujourd'hui une divergence constatée entre les
deux copies, pas une hypothèse.

### 1. Ce qui ferme une carte

| | |
|---|---|
| `pull-request` | Le merge humain, par la ligne `Closes #N` de la PR. |
| `trunk` | Le déploiement réussi du commit, par un workflow du consommateur. |

C'est la racine ; les six autres en découlent.

### 2. La définition de « déjà livrée »

`gh-next-issue.sh` doit savoir quelles cartes ne pas ressortir de la file.

En `pull-request`, une carte est livrée quand une PR ouverte la référence : le
label `factory:delivered` marque cet état, et la carte reste **ouverte** jusqu'au
merge.

En `trunk`, il n'y a pas d'état intermédiaire à marquer — la carte est
**fermée**, et c'est tout. Le `gh-next-issue.sh` de PSR le dit :

> the card's delivered state is not a label

### 3. Le label `factory:delivered`

Il n'existe qu'en mode `pull-request`. Vérifié : les deux copies sèment le même
jeu de labels à une exception près, et c'est celle-là.

`gh-seed-labels.sh` doit donc semer un jeu qui dépend du mode. Un label semé pour
rien n'est pas neutre : il apparaît dans l'interface, quelqu'un finit par le
poser à la main, et la file se met à mentir.

### 4. Le critère de déblocage

`gh-unblock.sh` rend une carte à la file quand son bloqueur a livré. « A livré »
n'a pas le même sens des deux côtés, et les deux fichiers portent le
raisonnement dans leur en-tête.

En `pull-request`, **une PR ouverte suffit** — attendre le merge ferait dépendre
la file d'un geste humain qui peut tarder des jours, alors que le travail
bloquant, lui, existe déjà et est consultable.

En `trunk`, seule la **fermeture** compte, parce qu'elle signifie précisément que
le travail a atteint la preprod. Le fichier de PSR :

> closure there meant "a human has merged" \[…\] closed by
> `factory-close-cards.yml` when its commit has passed the suite AND \[reached
> the preprod\]

### 5. L'entretien de ce qui est livré

En `pull-request`, `gh-pr-attention.sh` réveille une PR sur laquelle le relecteur
a parlé, et fait de sa parole du travail. En `trunk`, il n'y a aucune PR à
entretenir sur le chemin d'une carte — la surface de relecture est ailleurs (voir
« ce qui reste de la politique »).

Le script ne doit donc pas être appelé en mode `trunk`. Aujourd'hui il l'est
inconditionnellement.

### 6. La sérialisation

En `pull-request`, plusieurs cartes peuvent avancer de front : chacune vit sur sa
branche, et les PR s'empilent.

En `trunk`, la boucle **doit** attendre le déploiement avant de pousser la carte
suivante, et cette attente est structurelle : le `concurrency:
cancel-in-progress` du workflow ferait qu'un nouveau push annule le déploiement
du précédent — donc la fermeture de la carte précédente, qui resterait ouverte
sans que personne puisse dire pourquoi.

Une carte à la fois n'est donc pas une préférence en mode `trunk`, c'est une
condition de correction.

### 7. Le modèle d'espace de travail

Il découle du transport, et c'est le `resume.sh` de PSR qui l'énonce le mieux :

> with no pull requests there is no reason to hold one environment per card. The
> factory works ONE card at a time, on `staging`, in the tree the loop runs from.

En `pull-request` : un worktree par carte, `wt-cleanup.sh` détruit ceux dont la
PR est retombée, `wt-resume.sh` cherche le travail inachevé **dans les
worktrees**.

En `trunk` : un seul arbre, et la reprise cherche le travail inachevé **dans
l'arbre courant**, le numéro de carte étant relu **dans les commits** (`Refs #N`)
plutôt que dans un nom de répertoire.

## Ce que la clé ne gouverne pas

Tout le reste est de la **politique**, donc un crochet, donc chez le
consommateur. La frontière est celle du README : ce qui varie d'un déploiement à
l'autre est une clé, ce qui relève d'un choix de projet est un crochet, ce qui
est du mécanisme remonte ici.

Restent donc explicitement dehors :

- **La PR de promotion permanente** de PSR (`gh-promotion-pr.sh`,
  `gh-review-cards.sh`, `promotion-pr-body.md`). Elle est *une* réponse au
  problème « le mode `trunk` supprime la surface de relecture » — élégante, mais
  pas la seule : un autre consommateur pourrait vouloir un canal Slack, un
  rapport quotidien, rien du tout. La rendre obligatoire ferait de la clé une
  copie de PSR portant un autre nom.
- **La fermeture des épopées** (`gh-close-epics.sh`) : un choix de tableau.
- **Le triage d'alertes propres au produit** (PostHog chez les deux, avec deux
  implémentations) : déjà un crochet, `housekeeping`.
- **Ce qui ferme réellement la carte en mode `trunk`** : le workflow du
  consommateur. L'usine ne sait pas ce qu'est « la preprod » — chez PSR c'est
  Laravel Cloud, ailleurs ce sera autre chose. L'usine sait seulement qu'en mode
  `trunk` elle ne ferme pas les cartes et qu'elle attend le pipeline.

## Ce que le mode `trunk` exige du consommateur

Un mode qui délègue la garantie doit dire ce qu'il exige en échange, sinon il
offre un contrôle que personne ne tient. `factory doctor` doit refuser
`FACTORY_DELIVERY=trunk` tant que ces trois points ne sont pas satisfaits :

1. **Le push-to-deploy est désactivé**, et c'est la CI qui déclenche le
   déploiement, en aval d'une suite verte. Sans ça, un push déploie sans avoir
   rien prouvé, et le fait « que l'agent ne contrôle pas » redevient un fait
   qu'il contrôle.
2. **Un workflow ferme les cartes** sur déploiement réussi. Sans lui, aucune
   carte ne se ferme jamais et la file grossit en silence.
3. **Le tronc de l'usine n'est pas le tronc de production.** Le merge final reste
   un geste humain. Une usine en mode `trunk` pointée sur `main` n'a plus aucune
   barrière entre un agent et la production.

Le troisième point est le plus important, et c'est celui qu'une clé de
configuration mal comprise peut faire sauter d'un caractère.

## Le skill

La procédure de l'agent diverge sur les mêmes sept points, donc le skill aussi.
Trois formes possibles, et le choix n'est pas tranché ici :

- **deux skills** — le plus simple à lire, le plus sûr de diverger ;
- **un skill avec deux volets**, le mode sélectionnant le volet lu ;
- **un tronc commun plus un fragment par mode**, assemblé au lien.

Ce document recommande le deuxième, pour la raison qui a présidé à tout le reste :
les deux procédures partagent bien plus qu'elles ne divergent, et deux fichiers
séparés se réécrivent l'un sans l'autre. Mais c'est le point qui mérite le plus
d'être contesté avant d'être codé.

## Ce que ce document ne résout pas

- **Les fuites de code retour.** `api | python3` écrase la classification des
  pannes dans les deux copies (corrigé chez PSR par
  Paris-Showroom/website#211 et #212). C'est du mécanisme, et ça doit remonter
  ici — mais indépendamment de la clé.
- **La garde d'identité de `push-env.sh`** (Paris-Showroom/website#213) : déjà
  présente en amont, perdue chez PSR. Rien à faire ici.
- **La forme de la dépendance** (submodule ou input de flake). Orthogonal.
- **Le nom.** `FACTORY_DELIVERY` décrit ce qui varie ; si un meilleur nom existe,
  c'est maintenant qu'il faut le dire, pas après la première version épinglée.

## Vérification

Une clé de configuration ne se prouve pas en lisant le code : elle se prouve en
montrant que les deux modes produisent deux comportements, et que le défaut est
le plus sûr.

- La suite hors ligne joue **chaque script gouverné dans les deux modes**, avec
  les faux existants pour `curl` et `docker`. Un script qui se comporte
  identiquement dans les deux modes n'a rien à faire dans la liste des sept.
- `FACTORY_DELIVERY` absent ⇒ `pull-request`, et un test le fixe : c'est ce qui
  garantit qu'aucun consommateur existant ne change de comportement en montant de
  version.
- `FACTORY_DELIVERY` avec une valeur inconnue ⇒ **sortie 3**, jamais un repli
  silencieux. Une faute de frappe qui livrerait dans le mauvais mode est
  exactement la panne que ce document existe pour empêcher.
- `factory doctor` refuse `trunk` tant que les trois exigences ci-dessus ne sont
  pas vérifiables, et **nomme celle qui manque**.
