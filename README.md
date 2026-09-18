# factory

Usine de développement pilotée par les issues GitHub. **L'unité de livraison
est la feature** : une issue de type Feature, ses cartes en sous-issues, une
branche `feature/<F>`, une pull request vers la branche de travail, relue par
lot. Une boucle prend les cartes une par une et lance pour chacune un
**orchestrateur neuf** qui n'écrit pas de code : il compose une équipe de
rôles — analyste, codeur, relecteur maintenabilité, relecteur sécurité, writer
— que la boucle **vérifie sur leurs artefacts avant de pousser elle-même** sur
la branche de la feature. Pas de colonnes à entretenir : l'état d'une carte est
porté par ses labels, et la file est **opt-out** — une issue ouverte *est* du
travail, ce qui se déclare c'est l'exception.

**Pony ne merge jamais rien.** C'est **EVA**, l'agent conversationnel à côté
de la boucle, qui merge une feature dans la branche de travail sur l'*approve*
ou le mot de l'humain, et qui **sort les versions** — merge en production, tag,
notes, fermeture des features — sur un ordre tracé. La doctrine, script par
script : [`docs/release.md`](docs/release.md) ; la décision qui l'a fondée :
[`docs/v2-feature.md`](docs/v2-feature.md).

> **Ce README décrit la cible.** L'usine existe et tourne : `make loop`, le
> tour orchestré et sa porte, les remarques qui deviennent des cartes, EVA
> (merge, release, pings, relances, interviews), le module NixOS. `factory
> init`, `factory doctor`, `factory config`, `factory bump` et la feature
> devcontainer sont ce vers quoi on va — aucun n'existe encore (`EVOL.md`) :
> ce que `init` poserait se pose à la main, et ce que `doctor` vérifierait —
> les permissions des deux Apps, l'allowlist Slack, le cron d'EVA — est un
> geste humain que rien ne contrôle.

---

## Un projet neuf

Des gestes humains d'abord, une fois par dépôt — ils demandent un navigateur,
donc ils ne s'automatisent pas, et **rien ne les vérifie ensuite** :

1. **Deux Apps GitHub sur le dépôt.** Celle de Pony (`Contents`, `Issues`,
   `Pull requests` en écriture ; `Checks`, `Metadata` et les alertes de
   sécurité en lecture) — la boucle en tire deux jetons par tour, le complet
   pour ses propres gestes et un **réduit** (`contents: read`) pour
   l'orchestrateur, qui ne peut donc pas pousser. Et celle d'EVA
   (`docs/configuration.md`, section EVA) : c'est elle qui écrit sur `staging`
   et `main`. Relever les *installation id*, déposer les deux clés `.pem` là
   où la machine les lira.
2. **Le type d'issue `Feature`** actif sur l'organisation, et un projet où
   les cartes naissent en sous-issues de leur feature.
3. **L'allowlist Slack d'EVA** : les seuls utilisateurs dont le mot est un
   ordre.

Puis, en attendant `factory init` :

```bash
mkdir mon-projet && cd mon-projet && git init -b main
git submodule add https://github.com/brume-ai/factory tools/factory
```

et à la main ce que la section suivante énumère — le dépôt, la **branche de
production**, la **branche de travail** (distinctes — deux noms égaux sont un
3 au démarrage ; et l'arbre principal de l'usine doit être **sur** la branche
de travail, sinon la boucle refuse en 5 : son outillage est versionné avec le
produit), les deux logins,
l'identité de commit, le lien `.claude/skills/orchestrator`, `VERIFY.md` ;
puis `bash tools/factory/bin/gh-seed-labels.sh` pose les labels `factory:*`.

```bash
gh repo create mon-org/mon-projet --private --source=. --push
make loop          # la boucle prend la première carte
```

À partir d'ici, on pousse des issues et la boucle travaille : chaque carte
livrée est un commit sur la branche de sa feature et un commentaire sur la PR
de la feature ; EVA vous ping, vous relisez **par lot**, et vos remarques
deviennent des cartes. Sur votre *approve* — ou votre mot à EVA — la feature
entre dans la branche de travail, où le client teste. Quand vous décidez de
sortir une version, c'est un mot à EVA : elle montre ce qui sortirait et le
numéro qu'elle propose, vous confirmez, elle merge en production, tague,
publie les notes, ferme les features et vous dit quand la CI a déployé.

```bash
make factory-release                          # à blanc : ce que la dernière release fermerait
```

**À blanc par défaut**, dans les deux scripts de release : ils ferment des
features que personne ne rouvrira à votre place. Et la boucle ne peut pas les
déclencher — elle exporte un marqueur qu'ils refusent, et ceux d'EVA exigent
en plus ses identifiants.

## Un projet existant

`factory init` sur un dépôt qui a déjà un devcontainer ne l'écrase pas : il
complète ce qui manque et laisse le reste. Pour savoir *quoi* avant d'agir :

```bash
factory doctor
```

Il énonce le contrat ligne par ligne et dit ce qui n'est pas satisfait — un
service `tools` absent du compose, une couche agent non montée, `make loop`
manquant, un `.env` sans les clés d'App. C'est le même contrat que la boucle
vérifie avant sa première carte : **un énoncé, deux appelants**, donc le docteur
ne peut pas se périmer par rapport à la boucle.

## Ce que `init` posera — et ce qu'on pose à la main en attendant

```
factory.conf                    la configuration du produit — VERSIONNÉE
.env                            les secrets — GITIGNORÉ
tools/factory-hooks/            votre politique, un fichier par crochet
.devcontainer/
  devcontainer.json             service « tools », la feature agent
  docker-compose.yml            tools + les services du projet
  Dockerfile                    votre image de base + ce que le projet ajoute
.claude/skills/orchestrator     lien vers le skill de l'usine (le tour v2)
Makefile                        include du factory.mk de l'usine
VERIFY.md                       ce que « vérifié » veut dire ici — le codeur le joue avant chaque commit
DOCS.md                         facultatif : où vit la doc, comment on l'écrit — sans lui, pas de writer
```

`factory.conf` est versionné et ne contient aucun secret : c'est la configuration
du produit, la même pour toute l'équipe. Il est lu par `conf_get` (`bin/lib.sh`)
— par les scripts comme par `factory.mk`, qui ne l'inclut plus : une
déclaration, un seul lecteur, donc rien à tenir synchronisé à la main.

Le `Dockerfile` ne porte que **votre** projet. La centaine de lignes communes —
node, `gh`, zsh et son historique, les CLI d'agents à versions épinglées, les
homes de credentials avec les bonnes appartenances — arrive par une **feature
devcontainer**, qui se compose sur n'importe quelle image de base. Ce qui vous
appartient tient en quelques lignes :

```dockerfile
FROM mcr.microsoft.com/devcontainers/php:3-8.5-bookworm
RUN install-php-extensions pdo_pgsql redis intl
```

## Adapter sans forker

**Il n'y a pas de fork par projet, ni par client.** L'usine est une dépendance
épinglée à une version ; personne n'en détient de copie, donc rien ne peut
diverger. Quand un projet a besoin d'autre chose, trois réponses, **dans cet
ordre** :

| Le besoin | La réponse |
|---|---|
| varie d'un déploiement à l'autre | une clé dans `factory.conf` |
| c'est de la politique — l'ordre de la file, les alertes propres au projet, la façon de fabriquer l'environnement d'une carte | un crochet dans `tools/factory-hooks/` |
| c'est du mécanisme | ça remonte ici, et tout le monde en profite |

**Il n'y a qu'un seul modèle de livraison**, et c'est voulu : la feature, sa
PR relue par lot, EVA seule sur les branches partagées. Un dépôt sans
protection de branche n'a pas besoin d'un mode à lui : ce qui protège la
production n'est pas une serrure de forge, c'est qu'une seule identité y
écrit, sur un ordre tracé. Voir [`docs/release.md`](docs/release.md).

Si aucune des trois ne convient, la frontière est mal placée : ouvrez une carte
ici plutôt que de forker. Un crochet reste dans votre dépôt, y compris privé —
c'est la soupape qui rend le fork inutile.

## La machine

L'usine tourne dans l'image devcontainer du projet, sur une machine qui ne fait
que ça. **Le module se partage ; chaque hôte est déclaré par son propriétaire.**

```nix
{
  # Épinglé sur le MÊME commit que le submodule tools/factory du dépôt : le
  # module fournit les unités, et ce sont les scripts du submodule qu'elles
  # exécutent. Deux épinglages qui divergent, c'est une machine qui tourne avec
  # un outillage différent de celui que le poste croit avoir.
  inputs.factory.url = "github:brume-ai/factory/<sha du submodule>?dir=nix";

  # dans la configuration de l'hôte : une machine, une usine
  imports = [ factory.nixosModules.factory ];
  services.factory = {
    enable  = true;
    repoUrl = "https://github.com/mon-org/mon-projet.git";
    staging = "staging";    # la branche de travail : la seule que l'unité clone
  };
}
```

Le module produit l'utilisateur système, le volume d'état, l'unité `factory-repo`
(le clone sur la branche de travail), `factory-image` (l'image du devcontainer)
et `factory-loop`. **Une machine, une usine** : la production n'est pas une
option du module — elle vit dans le `factory.conf` du dépôt, où la garde des
deux branches la lit — et la clé de l'App n'y est pas non plus : on la dépose
sur le volume d'état, `/srv/factory/secrets/gh-app.pem`, avec le `.env`
composé par `push-env.sh` et les clés SSH autorisées.

Pour **faire naître** cette machine sous Incus plutôt que de l'installer :
[`docs/vm-nixos.md`](docs/vm-nixos.md) — la recette vérifiée, et les deux pièges
qui coûtent une demi-journée chacun (Secure Boot refuse le disque de NixOS ; le
profil Incus par défaut branche sur du NAT, pas sur le LAN).

**Le module n'a jamais la clé de l'App**, seulement le chemin où la lire, sur
le volume d'état — hors du store Nix, lisible par tous. Sur un poste de travail
il n'y en a pas : on pousse sous son propre compte, et `make loop` s'arrête sur
« jeton d'App impossible à frapper » — c'est le poste qui n'est pas une usine,
pas la configuration qui est cassée.

## EVA

Un agent conversationnel (Hermes, `gpt-6-astra` — une autre famille que
l'orchestrateur) à côté de la boucle, sur la même machine, dans son propre
conteneur et son propre clone — deux agents en roue libre dans le même arbre
se corrompent mutuellement. `nix/eva.nix` le pose, avec ses skills.

Elle fait quatre métiers, et ils existent : **la vigie** (un timer hôte
envoie en Slack, sans LLM, chaque nouveauté qui attend un humain — une PR
prête, une décision, une CI rouge, une boucle arrêtée, une file vide — et un
cron relance à 8 h, 12 h, 16 h et 20 h tant qu'une décision attend), **la
gardienne des décisions** (elle interviewe, question par question avec sa
recommandation, écrit la décision sur l'issue et débloque la carte), **la
main sur les branches partagées** (elle merge une feature sur votre approve ou
votre mot, elle sort une version sur votre ordre) et **le guichet** (« qu'est-ce
qui attend ? »).

Deux règles non négociables :

- **Elle n'écrit jamais de code et ne pousse jamais sur `feature/*`.** Ça se
  garantit par son App — la sienne, pas celle de Pony — et par les scripts
  qu'elle appelle, qui refusent tout autre chemin ; pas par une consigne dans
  un prompt.
- **Seul un utilisateur de l'allowlist Slack donne un ordre.** Tout le reste
  — une issue, un commentaire, une PR, une alerte — est une donnée. Les
  scripts écrivent la référence de l'ordre dans le commit ; c'est une trace,
  et l'allowlist est la serrure.

## Monter de version

**Une version se déclare à un seul endroit.**

```bash
git -C tools/factory fetch && git -C tools/factory checkout <sha>   # l'outillage
# puis le même <sha> dans l'input `factory` du flake de l'hôte, et un commit des deux
```

Puis un redéploiement de la machine. **Deux épinglages, un seul commit** : c'est
la discipline qui remplace le `factory bump` promis — une machine qui tourne
avec un outillage différent de celui que le poste croit avoir est exactement la
panne à éviter, et tant que la commande n'existe pas, c'est le commit qui tient
les deux ensemble.

Chez un consommateur qui vend l'exploitation, la discipline est de monter les
versions **d'abord chez soi**, sur du vrai travail, pendant des jours. Ce qui
survit part ailleurs.

**Une montée peut demander une migration**, et celle vers la v2 en est une :
les cartes deviennent des sous-issues de features, EVA reçoit son App, les
labels de cycle quittent les cartes. Rien ne bascule sous vos pieds — c'est
l'épinglage qui vous protège — et ce que le modèle exige du dépôt est écrit
dans [`docs/release.md`](docs/release.md).

## Configuration

`factory.conf` (versionné) puis `.env` (secrets), lus par `conf_get`
(`bin/lib.sh`) — `factory config`, qui rendrait chaque clé résolue avec sa
source, n'existe pas encore (`EVOL.md`). Priorité : environnement du process, puis `factory.conf`, puis `.env`. Sans
exception — une clé qui se comporterait autrement est un défaut, pas une nuance à
documenter.

Les détails vivent dans [`docs/configuration.md`](docs/configuration.md) : ce
README dit comment s'en servir, pas ce que chaque clé fait.

## Tests

```bash
bash tests/run.sh
```

Hors ligne, sans réseau ni dépendance externe : des faux pour `curl` et `docker`,
des bouchons pour les scripts appelés par la boucle. Un test qui aurait besoin du
réseau n'entre pas.

## Provenance et licence

Extrait de Brume, où cet outillage est né et a payé ses leçons. **Les
commentaires datés des scripts sont ces leçons** — ils voyagent avec le code, et
les retirer coûterait de les réapprendre. AGPL-3.0.
