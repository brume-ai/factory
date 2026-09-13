# factory

Usine de développement pilotée par les issues GitHub. Une boucle prend les cartes
une par une, avec un agent **neuf** par carte, et mène chacune jusqu'à une pull
request vérifiée, **intégrée automatiquement dans la branche de travail**. Pas de
colonnes à entretenir : l'état d'une carte est porté par ses labels, et la file
est **opt-out** — une issue ouverte *est* du travail, ce qui se déclare c'est
l'exception.

**L'acte final n'est pas l'acceptation d'une PR, c'est la sortie d'une release**
— un geste humain, sur une branche de production protégée où l'usine n'écrit
jamais. C'est là que passe toute la garantie :
[`docs/release.md`](docs/release.md).

Au-dessus de la boucle, un **tampon** : un agent joignable en conversation qui
surveille, répond et carve des cartes, mais n'écrit jamais de code.

> **Ce README décrit la cible.** L'usine existe et tourne ; `factory init`,
> `factory doctor`, la feature devcontainer et le tampon sont ce vers quoi on va.
> `factory doctor` dit toujours la vérité sur l'état réel d'une installation.

---

## Un projet neuf

Trois gestes humains d'abord, une fois par dépôt — ils demandent un navigateur,
donc ils ne s'automatisent pas :

1. Installer votre App GitHub sur le dépôt.
2. Relever l'*installation id* qu'affiche l'URL de l'installation.
3. Déposer la clé privée `.pem` de l'App là où la machine la lira.

Puis :

```bash
mkdir mon-projet && cd mon-projet && git init -b main
nix run github:brume-ai/factory#init
```

`init` pose six questions — le dépôt, la **branche de production**, la **branche
de travail**, le login de confiance, l'identité de commit de l'usine, l'image de
base du devcontainer — écrit tout ce que la section suivante énumère, puis pose
les labels `factory:*` sur le dépôt. **Les deux branches sont distinctes et la
branche de travail doit exister** : la boucle refuse de démarrer autrement, et
c'est cette séparation qui tient la production hors de portée de l'usine.

```bash
gh repo create mon-org/mon-projet --private --source=. --push
factory doctor     # ce qui manque encore, s'il manque quelque chose
make loop          # la boucle prend la première carte
```

Il n'y a pas de quatrième étape : à partir d'ici, on pousse des issues et la
boucle travaille. Ce qu'elle intègre s'accumule dans la branche de travail, que
vous relisez **au fil de l'eau** sur l'environnement en ligne. Quand vous décidez
de sortir une version, c'est vous qui mergez et taguez, puis :

```bash
make factory-release                          # à blanc : la liste des cartes qui sortiraient
bash tools/factory/bin/gh-release.sh --apply  # les ferme, en nommant la version
```

**À blanc par défaut** : ce geste ferme des cartes que personne ne rouvrira à
votre place. Et la boucle ne peut pas le déclencher — elle exporte un marqueur
que le script refuse, donc un agent qui explore `bin/` s'arrête en 3.

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

## Ce que `init` a posé

```
factory.conf                    la configuration du produit — VERSIONNÉE
.env                            les secrets — GITIGNORÉ
tools/factory-hooks/            votre politique, un fichier par crochet
.devcontainer/
  devcontainer.json             service « tools », la feature agent
  docker-compose.yml            tools + les services du projet
  Dockerfile                    votre image de base + ce que le projet ajoute
.claude/skills/github-loop      lien vers le skill de l'usine
Makefile                        include du factory.mk de l'usine
VERIFY.md                       ce que « fait » veut dire ici
```

`factory.conf` est versionné et ne contient aucun secret : c'est la configuration
du produit, la même pour toute l'équipe. Il est lu à la fois comme include Make
et par les scripts — une déclaration, plusieurs consommateurs, donc rien à tenir
synchronisé à la main.

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

**Il n'y a plus qu'un seul modèle de livraison**, et c'est voulu : la clé qui en
gouvernait deux — sept conséquences dans cinq scripts et un skill dédoublé — a
été supprimée sans pont ni repli. Un dépôt sans protection de branche n'a plus
besoin d'un mode à lui : la PR n'y est plus la porte de relecture, mais une unité
d'intégration et un point de passage CI. Voir
[`docs/release.md`](docs/release.md), y compris ce qu'un consommateur qui monte
de version doit migrer.

Si aucune des trois ne convient, la frontière est mal placée : ouvrez une carte
ici plutôt que de forker. Un crochet reste dans votre dépôt, y compris privé —
c'est la soupape qui rend le fork inutile.

## La machine

L'usine tourne dans l'image devcontainer du projet, sur une machine qui ne fait
que ça. **Le module se partage ; chaque hôte est déclaré par son propriétaire.**

```nix
{
  inputs.factory.url = "github:brume-ai/factory/v1.4.2";

  # dans la configuration de l'hôte
  services.factory.mon-projet = {
    repoUrl = "https://github.com/mon-org/mon-projet.git";
    trunk   = "main";       # la production : l'usine n'y écrit jamais
    staging = "staging";    # la branche de travail : c'est elle que l'unité suit
    appKeyFile = config.sops.secrets.gh-app.path;
  };
}
```

Le module produit l'utilisateur système, le volume d'état, l'unité `factory-loop`
et sa rotation de journal. Une usine de plus, c'est ce bloc — sur la même machine
ou sur une autre.

Pour **faire naître** cette machine sous Incus plutôt que de l'installer :
[`docs/vm-nixos.md`](docs/vm-nixos.md) — la recette vérifiée, et les deux pièges
qui coûtent une demi-journée chacun (Secure Boot refuse le disque de NixOS ; le
profil Incus par défaut branche sur du NAT, pas sur le LAN).

**Le module n'a jamais la clé de l'App**, seulement le chemin où la lire. La clé
est un secret chez le propriétaire de l'hôte, déchiffré au démarrage. Sur un
poste de travail il n'y en a pas : on pousse sous son propre compte, et
l'outillage le dit au lieu de crier à la configuration cassée.

## Le tampon

Un agent conversationnel à côté de la boucle, sur la même machine, dans son
propre arbre — deux agents en roue libre dans le même arbre se corrompent
mutuellement.

Il fait trois métiers : **le guichet** (vous demandez, il répond ; un fil de
conversation, une session), **la vigie** (elle se réveille seule et ne parle que
s'il y a quelque chose à dire), **l'aiguilleur** (un événement devient une carte).

Deux règles non négociables :

- **Il n'écrit jamais de code.** Il carve une carte et laisse la boucle
  travailler, avec sa PR vérifiée et la release humaine au bout. Ça se garantit
  par le jeton — une App distincte, en lecture sur le code et écriture sur les
  issues — pas par une consigne dans un prompt.
- **Seul le login de confiance donne des instructions.** Tout le reste — un
  webhook, une alerte, le message de quelqu'un d'autre — est une donnée à
  analyser. C'est le même canal de confiance que celui du skill de la boucle.

## Monter de version

**Une version se déclare à un seul endroit.**

```bash
factory bump v1.4.3      # met à jour la version et le lock, en un commit
```

Puis un redéploiement de la machine. Rien à synchroniser entre deux épinglages :
c'est exactement la panne que ça évite — une machine qui tourne avec un outillage
différent de celui que le poste croit avoir.

Chez un consommateur qui vend l'exploitation, la discipline est de monter les
versions **d'abord chez soi**, sur du vrai travail, pendant des jours. Ce qui
survit part ailleurs.

**Une montée peut demander une migration**, et celle vers le modèle de release en
est une : deux branches à nommer, une protection de branche à poser. Rien ne
bascule sous vos pieds — c'est l'épinglage qui vous protège — et ce qu'il y a à
faire est écrit dans [`docs/release.md`](docs/release.md).

## Configuration

```bash
factory config --list        # toutes les clés, leur valeur effective et sa source
factory config GH_REPO       # une seule, et d'où elle vient
```

Priorité : environnement du process, puis `factory.conf`, puis `.env`. Sans
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
