# Évolutions

Les chantiers décidés mais pas encore faits, et **pourquoi**. Un chantier sort
d'ici quand il est livré : ce fichier ne garde pas trace de ce qui est fait,
`git log` le fait déjà mieux.

Chaque entrée porte la même forme : le fait qui la rend nécessaire, la décision,
ce qu'elle exige, et ce qui reste à vérifier. Une décision dont le fait n'est pas
écrit se rediscute tous les mois.

**L'ordre compte.** La v2 — la feature comme unité de livraison
(`docs/v2-feature.md`), la doctrine opérationnelle dans `docs/release.md` —
est livrée : le tour orchestré et sa porte, la boucle qui pousse elle-même,
EVA seule sur les branches partagées, les remarques qui deviennent des cartes,
les pings et les relances, les previews par PR sur la machine. Ce qui suit est
ce que la v2 a laissé de côté en le disant (1), ce qu'elle a changé d'objet
(2) et ce qu'elle n'a pas touché (3, 4, 5).

---

## 1. Fermer la classe adversariale de la porte — à uid égal

### Le fait

La porte (`turn-verify.sh`, rejouée par la boucle dans son propre
environnement) protège contre un orchestrateur qui **néglige** — socle
absent, verdict rouge, commit hors fenêtre, modèle non prouvé — pas contre un
qui **triche à uid égal** : il tourne sous le même utilisateur que `role.sh`
et peut fabriquer un `.brut`, un rollout codex, un artefact `.json` cohérent.
C'est dit dans `turn-verify.sh`, `factory.mk` et `docs/release.md` ; ce n'est
pas fermé.

**La moitié bon marché est faite.** L'orchestrateur reçoit un jeton d'App
**réduit** (`gh-app-token.sh --agent` : `contents: read`, `issues: write`,
`pull_requests: write`, `metadata: read`), et ni le credential helper ni
`FACTORY_TOKEN` : un `git push` de sa main est refusé par GitHub, pas par une
consigne (`loop.test.sh` le tient). Sa limite : il lit le `.env` et peut
refrapper un jeton complet avec `gh-app-token.sh` — la porte ferme la
négligence, pas la triche. C'est la classe observée le 17 septembre (un agent
seul, sans relecteur) qui a coûté, et elle est fermée ; celle-ci ne l'a jamais
été et n'a jamais coûté.

### La décision

Deux pièces, décidées, non faites :

1. **`role.sh` sous un uid distinct** de l'orchestrateur : les artefacts
   `.omc/turn/<carte>/` deviennent alors illisibles en écriture pour lui, et
   le `.env` (donc la clé de l'App) hors de sa portée — l'orchestrateur ne
   pourrait plus ni fabriquer une preuve ni refrapper un jeton.
2. **Des artefacts signés** : `role.sh` signe chaque `<rôle>-<k>.json` (et le
   `.brut` qu'il nomme) avec un secret que seul son uid lit ; `turn-verify.sh`
   vérifie la signature avant de relire quoi que ce soit.

### Ce qu'elle exige

Un second utilisateur dans le conteneur devcontainer avec **ses propres
logins** `claude` et `codex` (les homes de credentials sont montés pour un
seul utilisateur, `FACTORY_CONTAINER_USER`, par `run-loop.sh`) ; un `sudo`
borné, ou un service, pour que l'orchestrateur lance `role.sh` sans hériter de
l'uid ; un secret de signature sur le volume d'état, hors du `.env` que
l'orchestrateur lit.

### Ce qui reste à vérifier

- Que les CLI acceptent de tourner sous un uid qui n'est pas celui du home
  monté (les fichiers de session de `claude` et le `~/.codex/sessions` des
  rollouts, que `turn-verify.sh` relit).
- Le coût réel : un second jeu de logins par machine, à renouveler.

---

## 2. `factory doctor` — ce que la v2 laisse à un humain, et que rien ne vérifie

> **Réécrit après la v2.** Ce chantier disait « personne ne vérifie la
> protection de branche » ; la v2 n'a plus de serrure de forge par défaut, et
> ce qui protège la production est qu'une seule identité y écrit, sur un ordre
> tracé. Le docteur change d'objet, pas de raison d'être.

### Le fait

La v2 fait reposer sa garantie sur des réglages qu'un humain pose une fois, en
navigateur, et que **rien ne relit** :

- **les permissions des deux Apps** — celle de Pony (contents en écriture pour
  pousser sur `feature/*`, checks en lecture pour le verdict de CI, les alertes
  pour le triage) et celle d'EVA (contents, pull requests, issues en écriture ;
  checks, actions en lecture). Une permission manquante se voit au premier
  ordre par un 403 que les scripts nomment ; une permission changée reste **en
  attente d'acceptation** sur l'installation, et l'usine tourne avec l'ancienne
  sans un mot ;
- **l'allowlist Slack d'EVA** (`SLACK_ALLOWED_USERS`, `runtime.env`) — la seule
  serrure sur *qui ordonne*. `factory-eva` refuse désormais de démarrer si
  elle est absente ou vide ; **trop large**, rien ne le voit, et EVA merge et
  sort des versions sur le mot de n'importe qui ;
- **le cron de relance** `factory-relance`, créé par `factory-eva-setup` ; s'il
  manque (un `cron list` en échec au démarrage), les décisions attendent en
  silence — la panne du 17 septembre par une autre porte ;
- **le sous-module du clone d'EVA**, rafraîchi par `factory-eva-workspace` :
  s'il pointe un autre SHA que celui de la boucle, EVA merge et sort avec un
  outillage différent de celui qui a livré ;
- le type d'issue `Feature` actif sur l'organisation, les labels `factory:*`
  sous les noms de la configuration, la branche de travail sur le distant, le
  lien `.claude/skills/orchestrator`, `VERIFY.md`.

`factory doctor` n'existe toujours pas ; `bin/factory` fait `status | log |
deploy | stop | ssh`, et le README promet le docteur depuis le premier jour.

### La décision

Il énonce le contrat ligne par ligne et **nomme ce qui manque**, par ordre de
gravité : les deux Apps et leurs permissions effectives, l'allowlist, le cron,
le sous-module, puis le reste du contrat d'installation. **Un énoncé, deux
appelants** : le docteur et la garde de démarrage de la boucle lisent le même
contrat, sinon le docteur se périme par rapport à la boucle — et c'est le
docteur qu'on croit.

### Ce qu'elle exige

Un lecteur des permissions **effectives** d'une installation ; que le docteur
tourne sur la machine (l'allowlist et le cron n'existent que là) et sur un
poste (le contrat du dépôt) en disant lequel des deux il ne peut pas voir.

### Ce qui reste à vérifier

- La réponse de `POST /app/installations/<id>/access_tokens` porte un objet
  `permissions` : est-ce celui de l'installation (acceptée) ou celui de
  l'App (demandée) ? C'est la différence entre « posé » et « en attente ».
- `eva cron list` depuis l'hôte par `docker exec`, comme le fait déjà
  `factory-eva-setup`.

---

## 3. Sortir du verrou GitHub — un sujet de coût, relu après la v2

> **Réécrit deux fois** : après le modèle de release v1, qui réduisait
> l'exigence de forge à une protection de branche ; puis après la v2, qui
> l'a supprimée — et qui a, en échange, **élargi la surface d'API** dont
> l'usine dépend. La migration reste une question de facture ; elle coûte
> plus cher qu'avant.

### Le fait

La facture GitHub dépasse 100 $/mois, sur trois lignes : **sièges**, **minutes
Actions**, **add-on Security**. Et l'usine n'a qu'une forge dans les mains :
`curl` vers `api.github.com` dans une douzaine de scripts, `gh` dans le skill,
les conventions d'URL (`blob/…?raw=true`), le flux de jeton d'App, les trois
surfaces de sécurité — et, depuis la v2, **les sous-issues, les types d'issue,
les dépendances natives, `addSubIssue` et `markPullRequestReadyForReview` en
GraphQL, `/merges`, `/releases`, `/actions/runs`**. La feature, le lot, la
carte, la pile : tout le modèle est écrit sur des objets que seule GitHub
rend.

### Ce qui a été tranché

**Le périmètre : les dépôts produits bougent, la factory reste sur GitHub.** Sur
un dépôt **public**, GitHub donne gratuitement CodeQL, secret-scanning,
Dependabot et les Actions. Le jour où ce dépôt devient public
(`tests/hygiene.test.sh` existe pour ça), il ne coûte plus rien.

**Le candidat, c'est Forgejo. Pas GitLab.** Forgejo n'a qu'un seul palier et
son API est de forme GitHub (`/api/v1/repos/{owner}/{repo}/issues`). Mais il
n'a **ni sous-issues, ni types d'issue, ni dépendances natives** : le port
de la v2 y demande de reconstruire la hiérarchie feature → lot → carte
autrement (des labels, un corps structuré) — c'est la question qui décide,
et elle n'était pas posée avant la v2. La question des approbations
obligatoires, qui décidait avant, est devenue secondaire : le merge est le
geste d'EVA sur un ordre, pas une règle de forge.

**Deux des trois lignes se coupent sans changer de forge.**

| Ligne | Levier | Migration requise ? |
|---|---|---|
| Minutes Actions | runner auto-hébergé sur la machine déjà payée | **non** |
| Add-on Security | remplacer CodeQL + secret-scanning par du libre en CI | **non** |
| Sièges | Forgejo pour les dépôts produits | oui |

### L'ordre

1. **Runner auto-hébergé** sur la machine d'usine : la ligne « minutes » tombe
   à zéro sans toucher à l'architecture. Audit des sièges dans la foulée.
2. **Les faits Forgejo**, sur une instance jetable, un après-midi : (a) par
   quoi remplacer les sous-issues et les types d'issue sans perdre la vue de
   la feature ; (b) l'API des runs de CI ; (c) `/merges` et les releases.
3. **Reconstruire le triage de sécurité sur du libre, EN RESTANT SUR GITHUB.**
   Sur Forgejo il n'existe aucune API d'alertes : les substituts (Semgrep,
   gitleaks, Renovate) sont des **jobs de CI produisant des artefacts**.
   `gh-security-triage.py` doit apprendre à lire des artefacts — le plus gros
   morceau de découplage de forge du projet, et il coupe l'add-on tout de
   suite. Au passage, le triage d'alertes propres à un produit est de la
   politique, donc un crochet : **`gh-security-triage.py` sort du cœur et
   devient l'implémentation de référence du crochet `housekeeping`.**
4. **Extraire le port de forge avec GitHub SEUL derrière.** `bin/forge/`, un
   adaptateur, du **JSON normalisé** sur stdout — `gh-feature.py` et
   `gh-dependencies.py` sont déjà les seuls lecteurs de la hiérarchie et des
   dépendances, c'est là que la couture passera. La règle : *les adaptateurs
   normalisent, la logique ne branche jamais sur la forge*.
5. **Forgejo quand un dépôt réel bouge.** La deuxième implémentation est celle
   qui révèle où la frontière est fausse.
6. **Passer ce dépôt public**, dès que l'hygiène le permet.

### Ce que la migration laisse à faire

**L'authentification — une régression réelle.** Le jeton d'App GitHub vit une
heure, est scopé à l'installation, se réduit par permission (`--agent`) et
n'est lié à aucun humain. Forgejo n'a pas d'équivalent : un PAT long, sans
rotation, sans réduction — le jeton réduit de l'orchestrateur, qui ferme la
moitié bon marché du chantier 1, n'a pas de forme là-bas. À décider les yeux
ouverts.

### À vérifier

- [ ] **Les commits de l'App d'usine consomment-ils une licence GHAS ?**
      L'add-on est facturé **par committer actif** ; si `…[bot]` y figure,
      l'usine indexe sa note de sécurité sur son débit.
- [ ] Les faits Forgejo (étape 2).
- [ ] Ce que vaut Semgrep OSS face à CodeQL sur les dépôts réels.

---

## 4. La pagination — ce qui reste borné à cent

> **Le gros est fait.** `gh-next-issue.sh` suit l'en-tête `Link` sur la liste
> des cartes ; `deliver.sh`, `gh-pr-attention.sh`, `wt-cleanup.sh` et
> `gh-unblock.sh` suivent `Link` page après page ; `checks_verdict` (`lib.sh`) lit les
> contrôles page après page ; `gh-feature.py` pagine les sous-issues,
> `gh-dependencies.py` les dépendances, `gh-security-triage.py` tout.

Reste borné à cent, et chacun est dit ici pour le jour où ça ne suffira plus :
dans `eva-watch.sh`, les décisions ouvertes, les features `factory:staged`,
les PR ouvertes, les cartes d'alerte (les sous-issues de la feature
permanente, ou les issues ouvertes sans clé — c'est celle-là qui dépassera
cent la première), et par PR ses commits, ses reviews, ses contrôles ; dans
`eva-merge.sh`, les reviews d'une PR (le dernier mot du login humain pourrait
être au-delà) et ses contrôles (au-delà de cent, `truncated` **refuse** — sûr,
pas silencieux) ; dans `gh-release.sh`, les commentaires d'une issue où la
marque de version est relue (au-delà de cent commentaires sur une carte, un
second passage recommenterait). Cent suffit aujourd'hui.

---

## 5. Ce que la v2 laisse ouvert

Relu le 18 septembre 2026, après les cinq tranches. Ce qui a été corrigé l'a
été (`git log`) ; ce qui suit est ce qu'on a choisi de ne pas faire tout de
suite, et pourquoi.

- **Une PR de feature en conflit avec `staging`** est refusée par
  `eva-merge.sh` (« c'est une carte, pas un merge »), et **personne ne carve
  la carte** : `gh-pr-attention.sh` ne transforme que les remarques humaines
  et la CI rouge. C'est l'humain qui ouvre « rebaser feature/<F> » — à
  automatiser quand ça sera arrivé une fois.
- **Un merge réussi dont le label `factory:staged` n'a pas pu être posé**
  n'est rattrapé par personne : `eva-merge.sh` dit le geste manuel, et
  `eva-release.sh` bloque sur la feature tant qu'il manque. Le rattrapage
  (relire les PR de feature mergées dans `staging` sans label) est un tour de
  ménage de plus.
- **Pas de budget par tour** (durée, coût), que la spec prévoyait (§ 8) :
  `LOOP_MAX_RETRY` borne les retours d'une carte, rien ne borne un tour qui
  dure. La valeur se fixe sur mesure, après quelques tours réels.
- **Le message de `branches_require`** (deux branches égales) nomme encore la
  protection de branche comme ce qui protège — la doctrine v1 ; cinq tests
  l'assertent. À réécrire avec eux : ce qui protège est qu'EVA seule écrit.
- **`factory:delivered`** est encore semé par `gh-seed-labels.sh` et lu par
  le triage (une spec gelée) sans être posé par personne. À retirer du
  semis et du triage ensemble, ou à lui trouver un sens.
- **Une remarque sur une PR de feature déjà mergée** (la feature est dans
  `staging`, pas sortie) n'est vue par personne : `gh-pr-attention.sh` ne lit
  que les PR ouvertes. Le chemin est une carte neuve sous la feature, que
  `feature-up.sh` rouvre ; il est manuel.
- **Deux épinglages de version** (le flake de l'hôte et le submodule du dépôt)
  qui peuvent diverger : le README dit de les commiter ensemble ; `factory
  bump` n'existe pas.
- **Les previews ne sont pas derrière un proxy** (la spec § 2 en nommait un) :
  chaque preview est publiée sur son port, `FACTORY_PREVIEW_PORT_BASE + F`,
  par docker, **sur l'adresse LAN explicite de la machine** — docker publie
  par DNAT, en amont du pare-feu de l'hôte, qui ne voit pas ces ports ; ce
  qui borne l'exposition au LAN est l'adresse de publication et le réseau où
  vit la machine, pas une règle de pare-feu. Un proxy n'apporterait qu'un
  nom par PR, que le réseau ne sait pas résoudre sans DNS wildcard (§ 8). Et
  **l'inactivité n'est pas mesurée** : la preview s'éteint
  `FACTORY_PREVIEW_TTL` après la dernière demande `up` (8 h), pas après la
  dernière requête HTTP — mesurer les requêtes demanderait ce proxy.
- **`gh-release.sh` choisit la borne basse par date de création**, pas par
  distance dans le graphe : un correctif tagué APRÈS sur une ligne plus
  ancienne élargit la plage à blanc aux cartes déjà sorties — déjà
  commentées, donc sautées à l'`--apply`. Bruit dans la liste, pas de
  fermeture indue.
