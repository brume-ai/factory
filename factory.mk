# factory.mk : la boucle d'usine, a inclure depuis le Makefile du consommateur.
#   include tools/factory/factory.mk
# Configuration : factory.conf a la racine du depot (lignes KEY = VALUE, lues
# aussi par les scripts bash), surchargable par l'environnement et la ligne de
# commande make. Extrait de Brume (Makefile, section github-loop) au SHA
# 12ac9e92 ; les commentaires dates sont les lecons payees la-bas. La v2
# (docs/v2-feature.md) a remplace le tour : une feature = une branche = une PR,
# la boucle cree la branche et la PR, lance un ORCHESTRATEUR, verifie ses
# artefacts et pousse elle-meme.

# La recette de `loop` utilise des substitutions bash (`${var//motif/remplacement}`)
# pour injecter @ISSUE@/@FEATURE@/@WORKTREE@/@BASE@/@PR@ dans le prompt. `/bin/sh` pointe vers `dash`
# sur Debian/Ubuntu (donc sur les runners `ubuntu-latest`) : sans cette ligne, la
# recette y echoue en « Bad substitution » alors qu'elle marche partout ou `/bin/sh`
# se trouve deja etre bash (Fedora, par exemple). GNU Make resout un SHELL sans
# slash via le PATH, donc ce nom nu suffit.
SHELL := bash

FACTORY_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
FACTORY_BIN ?= $(FACTORY_DIR)/bin

# factory.conf N'EST PLUS INCLUS PAR MAKE, ET C'EST VOULU. Un include en
# faisait un SECOND lecteur de la configuration, plus faible que `conf_get`
# (pas de .env, guillemets gardes tels quels) et qui GAGNAIT sur l'environnement
# pour toute cle que le fichier definit — l'inverse du contrat « environnement,
# puis factory.conf, puis .env ». La tentative de le corriger en relevant
# l'environnement avant l'include et en le reposant apres passait chaque valeur
# par `$(eval …)`, ou un `#` ouvre un commentaire et un saut de ligne une
# nouvelle ligne de Makefile : sur la machine, `--env-file` injecte tout le .env
# dans l'environnement, et un secret portant un `#` arrivait tronque aux
# recettes, un shell exportant une fonction faisait echouer TOUTES les cibles.
# Les quelques cles que Make lit lui-meme passent donc par `conf_get`, dans un
# `$(shell)`, avec `?=` : l'environnement et la ligne de commande gagnent, puis
# factory.conf, puis .env — le meme ordre que partout, sans eval.
factory_conf = $(shell . "$(FACTORY_DIR)/bin/lib.sh" 2>/dev/null && FACTORY_ROOT="$(CURDIR)" conf_get "$(1)" "$(2)")

# Attente entre deux SONDAGES quand la file est vide. Le sondage coûte une requête
# HTTP, pas un agent : on peut donc attendre peu sans rien gaspiller. Une usine
# n'a pas à s'arrêter quand la file se vide — elle attend du travail.
LOOP_SLEEP     ?= $(call factory_conf,LOOP_SLEEP,60)
# Garde anti-tourniquet. Un agent qui rend la main sans faire avancer sa carte —
# typiquement parce qu'il a lancé une vérification EN FOND puis terminé son tour —
# la voit revenir au sondage suivant, et un agent NEUF repart de zéro. Observé le
# 2 août : quatre tours sur la même carte, quatre suites e2e complètes payées
# pour rien. Au-delà de ce compte, la boucle s'arrête et le DIT.
LOOP_MAX_RETRY ?= $(call factory_conf,LOOP_MAX_RETRY,3)
# `make loop` lance l'ORCHESTRATEUR en YOLO (--dangerously-skip-permissions, sans
# surveillance) sur Opus 5 à effort LOW, via CLAUDE_LAUNCH (surchargeable).
# L'ORCHESTRATEUR EST TOUJOURS CLAUDE : il n'écrit pas de code, il compose
# l'équipe et fait poper chaque rôle par bin/role.sh — Codex est un RÔLE (le
# codeur), pas un agent principal. `MAIN=codex` et son prompt « tu fais la carte
# de bout en bout toi-même » ont disparu avec la v2 : c'est exactement ce que
# docs/v2-feature.md § 4 interdit, et ce que turn-verify.sh refuse.
# Le prompt reste COURT À DESSEIN : toute la procédure vit dans le skill
# `orchestrator` — un fait, un endroit. La redire ici donnerait à l'agent deux
# copies concurrentes des mêmes ordres, ce qui le fait argumenter et s'arrêter
# trop tôt. Modifiez le skill, pas ce prompt.
# PAS FABLE 5 : voir la lecon du 7 aout dans l'historique Brume (pot de credits
# distinct, tours qui meurent en 4 s en ressemblant a une usine occupee).
CLAUDE_LAUNCH  ?= $(call factory_conf,CLAUDE_LAUNCH,claude --dangerously-skip-permissions --model claude-opus-5 --effort low)

FACTORY_BOLD := $(shell tput bold 2>/dev/null)
FACTORY_CYAN := $(shell tput setaf 6 2>/dev/null)
FACTORY_RST  := $(shell tput sgr0 2>/dev/null)

# Six marqueurs, substitués au lancement : la carte, sa feature (branche
# `feature/<F>` et PR déjà créées par feature-up.sh), le worktree (déjà sur la
# branche, outillage initialisé — l'orchestrateur y est lancé), la RACINE de
# l'arbre principal (les artefacts du tour vivent sous <racine>/.omc/turn/ — un
# chemin relatif depuis le worktree atterrirait dans le worktree, où la boucle
# ne regarde jamais), la base (le SHA de origin/feature/<F> à l'admission, ce
# contre quoi le diff se lit) et la PR.
# UN SEUL PROMPT : plus de reprise ni d'entretien. Un tour interrompu se
# reprend par la sélection normale (la carte porte `busy`, son répertoire de
# tour persiste), et les remarques sur une PR deviennent des cartes (D6).
LOOP_PROMPT ?= orchestrator : suis le skill. Carte \#@ISSUE@ du dépôt @REPO@, feature \#@FEATURE@ (branche feature/@FEATURE@, PR \#@PR@ — la boucle les a créées, tu ne les recrées pas). Worktree : @WORKTREE@ (tu y es lancé). Racine : @ROOT@ (les artefacts du tour vivent sous @ROOT@/.omc/turn/@ISSUE@/, jamais dans le worktree). Base : @BASE@. Un seul tour : compose l'équipe, fais poper chaque rôle par role.sh, n'écris aucun code toi-même, ne pousse JAMAIS. Pose @ROOT@/.omc/turn/@ISSUE@/pret quand turn-verify.sh rend 0, ou arrête-toi sur needs-human, refacto carvée, ou prémisse fausse prouvée. Tu ne rends JAMAIS la main en attendant un résultat. Puis stop.

LOOP_MAIN_BIN    := claude
LOOP_RUN_VERBOSE  = $(CLAUDE_LAUNCH) --output-format stream-json --verbose -p "$$prompt" | "$(FACTORY_BIN)/claude-stream.sh"
LOOP_RUN_QUIET    = $(CLAUDE_LAUNCH) -p "$$prompt"

## loop: la boucle v2 sur les issues GitHub — orchestrateur NEUF par carte, la boucle pousse (VERBOSE=1 pour suivre)
.PHONY: loop
loop:
	@command -v $(LOOP_MAIN_BIN) >/dev/null 2>&1 || { echo "$(LOOP_MAIN_BIN) CLI introuvable dans le PATH"; exit 1; }
	@# LES PREREQUIS DE L'OUTILLAGE, VERIFIES UNE FOIS : chaque script de bin/ lit
	@# du JSON en python3, frappe son jeton avec curl (et openssl, que gh-app-token.sh verifie lui-meme). Un python3
	@# absent faisait rendre 4 au frappeur — « rate passager » — et la boucle
	@# dormait puis recommencait, un jeton emis et jete a chaque tour, avec un
	@# message qui envoyait regarder le reseau.
	@for t in python3 curl git; do command -v $$t >/dev/null 2>&1 || { echo "factory.mk: $$t introuvable dans le PATH — l'usine en a besoin (voir docs/configuration.md)" >&2; exit 3; }; done
	@# LOOP_SLEEP ET LOOP_MAX_RETRY SONT DES ENTIERS, ET NON VIDES : une valeur
	@# vide (« LOOP_SLEEP = » dans factory.conf, ou exportee vide) n'est pas
	@# « non definie » pour Make, le defaut ne s'applique pas, et `sleep` sans
	@# operande echouait — sondage en continu contre l'API, jusqu'au quota.
	@case "$(LOOP_SLEEP)" in ''|*[!0-9]*) echo "factory.mk: LOOP_SLEEP doit etre un entier de secondes (« $(LOOP_SLEEP) »)" >&2; exit 3;; esac
	@case "$(LOOP_MAX_RETRY)" in ''|*[!0-9]*) echo "factory.mk: LOOP_MAX_RETRY doit etre un entier (« $(LOOP_MAX_RETRY) »)" >&2; exit 3;; esac
	@# IDENTITÉ DE COMMIT DE L'USINE. Une CI de dépôt consommateur qui vérifie
	@# l'auteur des commits (allowlist bot, check CLA...) refuse tout auteur
	@# qu'elle ne reconnaît pas. Sans identité explicite, l'agent signe avec
	@# l'identité git de son environnement d'exécution — un compte non lié à
	@# GitHub — la CI passe au rouge, et le tour SUIVANT paie un cycle complet
	@# pour réécrire le commit. Payé deux fois de suite chez Brume (cartes
	@# #33 puis #34) : ~25 min de CI et deux tours d'agent brûlés pour un
	@# champ d'auteur. Git lit GIT_AUTHOR_*/GIT_COMMITTER_* AVANT `user.name`,
	@# donc l'identité est bonne dès le premier commit, sans que l'agent ait
	@# à y penser.
	@# TOUTES LES CLES SONT LUES PAR bin/lib.sh, ET PAR PERSONNE D'AUTRE — les
	@# branches, mais aussi GH_REPO et l'identite de commit. Make POURRAIT les
	@# lire seul — le `-include factory.conf` ci-dessus lui donne les variables —
	@# mais ce serait un SECOND lecteur, et un lecteur strictement plus faible :
	@# `conf_get` lit l'environnement, PUIS factory.conf, PUIS .env, tolere
	@# `export`, les guillemets et un commentaire de fin de ligne ; Make ne lit
	@# que factory.conf, garde les guillemets tels quels, et une variable qu'il
	@# a lue dans le fichier GAGNE sur l'environnement — l'inverse du contrat
	@# « environnement, puis factory.conf, puis .env, sans exception ». Une cle
	@# posee dans le .env ou dans l'environnement donnait donc une valeur aux
	@# scripts et une AUTRE a la boucle, sans un mot ; sur un nom de branche ce
	@# desaccord silencieux est un chemin d'ecriture vers la production, sur
	@# l'identite de commit c'est une CI rouge au premier commit. Ce fichier ne
	@# definit donc aucune variable Make de configuration : la recette les lit
	@# par `conf_get`, dans le shell qui lance l'agent.
	@. "$(FACTORY_DIR)/bin/lib.sh" || { echo "factory.mk: $(FACTORY_DIR)/bin/lib.sh illisible" >&2 ; exit 3 ; } ; \
	export FACTORY_ROOT="$(CURDIR)" ; \
	conf_require GH_REPO FACTORY_GIT_NAME FACTORY_GIT_EMAIL
	@# LES DEUX GARDES TIENNENT DANS LE MÊME SHELL, à dessein. `branches_require`
	@# refuse en 3 quand la branche de PRODUCTION et la branche de TRAVAIL sont la
	@# même — l'usine publierait en production à chaque carte — puis NORMALISE
	@# (rognage, réapplication du défaut) et exporte ; son export meurt avec le
	@# shell qui l'appelle. Valider ici et comparer ailleurs ferait qu'avec
	@# FACTORY_STAGING = « staging » suivi d'une espace, la valeur qui gouverne ne
	@# serait jamais celle qui a été contrôlée.
	@# CE QUE LA SECONDE GARDE ATTRAPE : la boucle ne tourne QUE depuis la branche
	@# de TRAVAIL, parce que son outillage est versionné avec le produit. Observé
	@# le 2 août — un agent avait laissé l'arbre sur `card/7`, et la boucle a
	@# tourné avec un Makefile qui ignorait `gh-unblock.sh`, donc sans résoudre
	@# aucune dépendance. Rien ne le signalait : elle avait l'air de marcher. La
	@# vraie correction est ailleurs (les agents travaillent en worktree) ; cette
	@# garde attrape le jour où l'un d'eux l'oublie.
	@. "$(FACTORY_DIR)/bin/lib.sh" || { echo "factory.mk: $(FACTORY_DIR)/bin/lib.sh illisible" >&2 ; exit 3 ; } ; \
	FACTORY_ROOT="$(CURDIR)" branches_require ; \
	b="$$(git -C "$(CURDIR)" branch --show-current)" ; \
	if [ "$$b" != "$$FACTORY_STAGING" ]; then \
		echo "$(FACTORY_CYAN)— l'arbre est sur « $$b », pas sur la branche de travail « $$FACTORY_STAGING » : la boucle tournerait avec un outillage périmé. Revenez à la branche de travail. —$(FACTORY_RST)" ; \
		exit 5 ; \
	fi
	@. "$(FACTORY_DIR)/bin/lib.sh" ; FACTORY_ROOT="$(CURDIR)" ; \
	echo "$(FACTORY_BOLD)factory v2$(FACTORY_RST) — $$(conf_get GH_REPO) · orchestrateur : $(LOOP_MAIN_BIN).$(if $(VERBOSE), streaming ON.,) 'make loop-stop' pour finir la carte puis s'arrêter · Ctrl-C pour couper net."
	@# Sentinelle laissé par un run précédent : sans cette purge, la boucle
	@# s'arrêterait après une seule carte sans que personne ne l'ait demandé.
	@mkdir -p "$(CURDIR)/.omc" && rm -f "$(CURDIR)/.omc/loop.stop"
	@# `make loop-stop` pose un sentinelle relu entre deux cartes ET après l'attente :
	@# demandé pendant les $(LOOP_SLEEP)s, un arrêt lu trop tôt ferait partir une carte
	@# de plus, en silence. Ctrl-C ne peut pas rendre ce service — le SIGINT part au
	@# groupe entier, donc l'agent meurt au milieu de sa carte ; un trap n'y change rien.
	@# `|| rc=$$?` est OBLIGATOIRE, et l'ancienne raison écrite ici — « .SHELLFLAGS
	@# porte `-e` » — était fausse : ce fichier ne définit .SHELLFLAGS NULLE PART,
	@# donc rien n'arrête ce shell sauf un `exit`. La vraie raison est plus bête et
	@# plus dangereuse : `x="$$(cmd)" && rc=0` seul laisse `rc` à la valeur du tour
	@# PRÉCÉDENT quand la substitution échoue, donc « file vide » serait lue comme
	@# « carte servie » et un agent partirait sur un numéro vide.
	@# L'ORDRE D'UN TOUR (docs/v2-feature.md, D4) : (a) le ménage, (b) la
	@# sélection d'une carte, (c) sa feature — branche, worktree, PR —, (d) la
	@# préparation du tour, (e) l'orchestrateur, (f) au retour : la porte, puis
	@# la livraison. Plus d'ENTRETIEN de PR ni de REPRISE : une remarque sur une
	@# PR devient une carte (gh-pr-attention), un tour interrompu se reprend par
	@# la sélection normale (la carte porte `busy`, son répertoire de tour
	@# persiste). Et PLUS D'INTÉGRATION : `gh-stage-pr` a disparu avec la PR de
	@# carte — une carte est un commit sur la branche de sa feature, et Pony ne
	@# merge plus jamais rien, nulle part (§ 3).
	@# AVANT TOUT SONDAGE, LE MÉNAGE. D'abord détruire les environnements dont le
	@# travail a atterri (`wt-cleanup`, v2 : un worktree `feature-<F>` seulement si
	@# la PR de F est mergée ou fermée) : une pile abandonnée coûte 3 Go, une
	@# base, une route, et surtout UNE VOIE — le hook worktree-up du projet
	@# refuse d'en fabriquer une de trop. Un agent tué en route ne nettoie pas :
	@# c'est justement le cas qui laisse des restes.
	@# Puis : rendre à la file les cartes dont le bloqueur est tombé (`gh-unblock`).
	@# Une carte déclare sa dépendance nativement (ou en tête de corps, « Bloquée
	@# par #N ») — mais personne ne la résolvait quand #N tombait. Le 2 août,
	@# retirer les LABELS sans retirer le TEXTE a produit pire que l'immobilisme :
	@# cinq tours d'affilée à relire « Bloquée par », vérifier, et re-bloquer.
	@# LA SÉCURITÉ EST DU MÉNAGE, PAS UN SÉLECTEUR DE TRAVAIL. `gh-security-triage`
	@# ne rend aucun numéro et ne lance aucun agent : il transpose les alertes des
	@# onglets Security en ISSUES, puis se tait. C'est `gh-next-issue` qui les
	@# prend ensuite, sans nouveau chemin ni nouveau prompt — elles portent
	@# `factory:priority`, donc elles passent devant. Sa place est donc ici, en
	@# queue de ménage, et non dans la chaîne de sondage.
	@# Ces alertes ne sont dans AUCUNE file : ni `gh-next-issue` (qui lit les
	@# issues) ni `gh-pr-attention` (qui lit les PR) ne les voit. 232 Dependabot et
	@# 14 CodeQL y dormaient sans que personne ne soit envoyé.
	@# IL NE PEUT PAS SOURCER lib.sh : c'est donc SON APPELANT qui résout les noms
	@# de label et les lui passe, et le Python les lit sans défaut. Un défaut écrit
	@# en Python serait un second domicile pour un nom de label, invisible depuis
	@# factory.conf — le défaut même que `label_get` existe pour supprimer.
	@# UN RATÉ PASSAGER NE TUE PLUS L'USINE. Les sondages rendaient 3 — « mal
	@# configuré », donc arrêt — pour un DNS qui bafouille, un HTTP/2 déchiré, une
	@# réponse coupée en plein JSON. Cinq arrêts en sept jours, sous un message qui
	@# envoyait vérifier des `GH_APP_*` parfaitement bons. Le code 4 dit « réessaie
	@# plus tard » : la boucle dort comme sur une file vide, mais elle le DIT.
	@# Le 3 garde son sens strict — un refus de l'API qu'un humain doit réparer.
	@# Le sondage : UN seul appel. stdout porte le numéro (capturé), stderr porte
	@# l'explication (laissée filer vers le terminal). Sonder deux fois pour
	@# récupérer les deux flux exposerait à une carte qui change d'état entre les
	@# deux appels — et paierait deux requêtes pour une réponse.
	@# gh-pr-attention EST DU MÉNAGE AUSSI (D6) : chaque remarque humaine sur une
	@# PR de feature ouverte devient une CARTE sous la feature, et l'usine répond
	@# dans le fil ; une CI rouge devient une carte « Réparer la CI ». Il ne rend
	@# AUCUN numéro : les cartes neuves entrent dans la file, prioritaires, et
	@# c'est le sondage qui les prendra. Pony ne réagit jamais à un commentaire
	@# brut, il exécute une carte qu'on a rédigée (§ 5).
	@# UN JETON PAR TOUR, frappé en tête de tour et exporté (GH_TOKEN pour `gh`
	@# et l'agent, FACTORY_TOKEN pour les scripts de bin/). Chaque appel Bash
	@# d'un agent est un shell NEUF : un `export` posé par l'agent ne survit pas à
	@# son propre outil. Faute de quoi il choisit entre deux mauvaises options,
	@# et il a fait les deux — écrire le jeton dans /tmp (un secret sur disque,
	@# oublié si le tour meurt), ou le refrapper à CHAQUE commande, une
	@# trentaine de fois sur la carte #32. Frappé ici, il est hérité par tous les
	@# shells du tour. Il vit une heure ; une carte qui dépasse voit un 401, et le
	@# skill dit alors de le refrapper — par commande, puisqu'un export ne survit
	@# pas.
	@# LA BRANCHE DE TRAVAIL LOCALE AVANCE À CHAQUE TOUR, et pas seulement au
	@# démarrage. La garde du démarrage compare le NOM de la branche à la branche
	@# de travail, résolue par bin/lib.sh dans la recette ; elle ne dit rien de sa
	@# FRAÎCHEUR. Une PR est intégrée, l'arbre local reste au commit d'avant, et la
	@# boucle continue à exécuter l'outillage d'AVANT le correctif — scripts de
	@# `tools/factory/` et skill `orchestrator` — sans que rien ne le signale. C'est
	@# le défaut du 2 août (l'arbre laissé sur `card/7`) par une autre porte : bonne
	@# branche, contenu périmé. Les CARTES, elles, n'ont jamais souffert de ça — le
	@# skill fabrique chaque worktree depuis `origin/<base>` fraîchement fetché.
	@# `merge --ff-only` et pas `reset --hard` : `deploy.sh` peut se permettre le
	@# second parce que la VM d'usine n'a aucun travail humain, mais `make loop` se
	@# lance aussi depuis un poste, où l'arbre principal porte des modifications à
	@# quelqu'un. Un `reset --hard` les emporterait sans le dire. Le `ff-only`
	@# échoue proprement, et on dit pourquoi plutôt que de laisser un tour muet.
	@# PORTÉE EXACTE, pour ne pas croire plus que ce que ça fait : les scripts et le
	@# skill sont relus à chaque invocation, donc ils prennent effet dès ce tour-ci.
	@# Le Makefile, lui, est déjà parsé par le `make` en cours : un correctif qui le
	@# touche n'entre qu'au prochain démarrage de la boucle.
	@# `branches_require` EST RAPPELÉ ICI, et ce n'est pas une redite : l'export de
	@# la garde du démarrage est mort avec son sous-shell. Appel NU — dans un $$( )
	@# le 3 serait avalé et l'export n'atteindrait personne. Après lui,
	@# $$FACTORY_STAGING est la seule valeur lue par le fetch, le ff-only, les
	@# scripts de ménage et l'agent.
	@# FACTORY_IN_LOOP REND EXÉCUTABLE « LES GESTES D'EVA NE SE FONT JAMAIS DEPUIS
	@# UN TOUR ». Ce n'est pas une clé de configuration — personne ne la pose dans
	@# factory.conf ; trois scripts la lisent, `gh-release.sh`, `eva-merge.sh` et
	@# `eva-release.sh`, et refusent de partir quand elle est là. Sans elle la
	@# phrase n'est qu'une ligne de doc : l'agent hérite d'un jeton, tourne en
	@# --dangerously-skip-permissions, et rien ne l'empêcherait de fermer des
	@# features que personne n'a sorties.
	@. "$(FACTORY_DIR)/bin/lib.sh" || { echo "factory.mk: $(FACTORY_DIR)/bin/lib.sh illisible" >&2 ; exit 3 ; } ; \
	export FACTORY_ROOT="$(CURDIR)" ; \
	branches_require ; \
	export FACTORY_IN_LOOP=1 ; \
	GH_REPO="$$(conf_get GH_REPO)" ; export GH_REPO ; \
	export GIT_AUTHOR_NAME="$$(conf_get FACTORY_GIT_NAME)" GIT_AUTHOR_EMAIL="$$(conf_get FACTORY_GIT_EMAIL)" ; \
	export GIT_COMMITTER_NAME="$$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$$GIT_AUTHOR_EMAIL" ; \
	stop_asked() { \
		[ -f "$(CURDIR)/.omc/loop.stop" ] || return 1 ; \
		rm -f "$(CURDIR)/.omc/loop.stop" ; \
		echo "$(FACTORY_CYAN)— arrêt demandé : aucune nouvelle carte prise —$(FACTORY_RST)" ; \
		return 0 ; \
	} ; \
	# LA GARDE ANTI-TOURNIQUET VIT SUR DISQUE, PAS EN MEMOIRE. Sur la machine, \
	# la boucle tourne sous systemd avec Restart=always : un compteur en memoire \
	# repartait de zero a chaque relance, et une carte coincee coutait des \
	# agents a l'infini — LOOP_MAX_RETRY par vie de processus, un processus \
	# neuf toutes les trente secondes. Le fichier porte « sujet compte » ; il \
	# est efface quand un tour change de sujet, et par un humain qui relance \
	# apres avoir regarde ce qui bloquait. \
	retry="$(CURDIR)/.omc/loop.retry" ; halt="$(CURDIR)/.omc/loop.halt" ; \
	# UN ARRET VOLONTAIRE EST UN ARRET, MEME SOUS Restart=always. Le tourniquet \
	# sortait en 4 ; sur la machine, systemd relancait trente secondes plus \
	# tard, et chaque relance payait un jeton, un fetch et tout le menage avant \
	# de relire le compteur et de ressortir — sans alerte, jusqu'a une main. \
	# Le sentinelle est relu ICI, avant le premier geste : une relance s'arrete \
	# en une ligne, et dit quoi effacer. \
	if [ -f "$$halt" ]; then \
		echo "$(FACTORY_CYAN)— la boucle a ete arretee : $$(cat "$$halt"). Regardez, puis effacez $$halt et $$retry pour relancer. —$(FACTORY_RST)" ; \
		exit 4 ; \
	fi ; \
	last="" ; same=0 ; since=0 ; \
	if [ -f "$$retry" ]; then read -r last same since < "$$retry" || true ; fi ; \
	# LE COMPTEUR SE PERIME : un retour LEGITIME du meme sujet des jours plus \
	# tard (carte rouverte, PR fermee a la main) n'est pas un tourniquet. Plus \
	# vieux qu'un jour, il repart de zero. \
	if [ -n "$$since" ] && [ "$$since" -gt 0 ] 2>/dev/null && [ $$(( $$(date +%s) - since )) -gt 86400 ]; then last="" ; same=0 ; fi ; \
	while true; do \
		if stop_asked ; then break ; fi ; \
		# LA GARDE DE BRANCHE EST RELUE A CHAQUE TOUR, pas seulement au \
		# demarrage : un agent qui laisse l'arbre principal sur card/N ferait \
		# tourner tous les tours suivants sur cette branche, sans un mot. \
		b="$$(git -C "$(CURDIR)" branch --show-current)" ; \
		if [ "$$b" != "$$FACTORY_STAGING" ]; then \
			echo "$(FACTORY_CYAN)— l'arbre est passé sur « $$b » en cours de route : la boucle s'arrête plutôt que de tourner avec un outillage périmé. Revenez à « $$FACTORY_STAGING ». —$(FACTORY_RST)" ; \
			exit 5 ; \
		fi ; \
		# UN JETON PAR TOUR, FRAPPE EN TETE, ET IL SERT A TOUT : au fetch de \
		# fraicheur, au menage, aux sondages, a l'agent. Il etait frappe juste \
		# avant l'agent, donc APRES le fetch — qui tournait sans identifiant : \
		# sur la machine, ou le depot est prive et le conteneur n'a aucun \
		# credential helper, la branche de travail locale n'avancait JAMAIS, et \
		# le `2>/dev/null &&` taisait l'echec. Et chaque script de menage \
		# refrappait le sien : sept frappes par tour, sept chemins de panne. \
		# FACTORY_TOKEN est honore par tous les scripts de bin/ ; GH_TOKEN par \
		# `gh` et l'agent. Un rate passager a la frappe (4) fait dormir la \
		# boucle ; un refus (3) l'arrete, comme partout. \
		tok=0 ; GH_TOKEN="$$(bash "$(FACTORY_BIN)/gh-app-token.sh")" || tok=$$? ; \
		if [ "$$tok" = 4 ]; then \
			echo "$(FACTORY_CYAN)— jeton d'App : raté passager · nouvel essai dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			sleep $(LOOP_SLEEP) ; continue ; \
		elif [ "$$tok" != 0 ]; then \
			echo "$(FACTORY_CYAN)— jeton d'App impossible à frapper : configuration cassée. Arrêt. —$(FACTORY_RST)" ; exit 3 ; \
		fi ; \
		export GH_TOKEN ; export FACTORY_TOKEN="$$GH_TOKEN" ; \
		# UN SECOND JETON, RÉDUIT, POUR L'AGENT (docs/v2-feature.md § 4). Le jeton \
		# complet a `contents: write` : c'est lui qui pousse sur feature/*. \
		# L'orchestrateur et ses rôles n'ont besoin que de lire l'arbre et d'écrire \
		# des issues, des labels, des commentaires, des sous-issues — jamais de \
		# pousser. `gh-app-token.sh --agent` demande à GitHub un jeton qui ne \
		# PEUT pas pousser (contents: read) : le refus vient de GitHub, pas d'une \
		# consigne dans un skill. C'est la moitié BON MARCHÉ de la fermeture \
		# adversariale de la porte — un orchestrateur qui voudrait pousser \
		# lui-même trouve un 403 ; l'autre moitié (role.sh sous un uid distinct, \
		# artefacts signés) reste reportée (EVOL). Sa limite, dite : l'agent \
		# tourne sous le même uid et lit le .env ; il PEUT refrapper un jeton \
		# complet avec gh-app-token.sh — la porte ferme la négligence, pas la \
		# triche. Un raté à la frappe est traité comme pour le premier jeton. \
		tok=0 ; AGENT_TOKEN="$$(bash "$(FACTORY_BIN)/gh-app-token.sh" --agent)" || tok=$$? ; \
		if [ "$$tok" = 4 ]; then \
			echo "$(FACTORY_CYAN)— jeton d'App (agent) : raté passager · nouvel essai dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			sleep $(LOOP_SLEEP) ; continue ; \
		elif [ "$$tok" != 0 ]; then \
			echo "$(FACTORY_CYAN)— jeton d'App (agent) impossible à frapper : configuration cassée. Arrêt. —$(FACTORY_RST)" ; exit 3 ; \
		fi ; \
		# GIT POUSSE AVEC LE JETON DE gh, ET C'EST LA BOUCLE QUI LE DIT A GIT — AUX \
		# SEULS GESTES QUI POUSSENT. Le conteneur n'a aucun credential helper et \
		# son ~/.gitconfig ne survit pas : sans GIT_CONFIG_*, `git push` demande un \
		# mot de passe que personne ne tape. Ces trois variables ne sont PLUS \
		# exportées au tour entier : elles sont données nommément à feature-up.sh \
		# et deliver.sh (les deux seuls scripts qui poussent), et le fetch de \
		# fraîcheur porte son en-tête lui-même. L'agent est lancé avec `env -u` : \
		# il n'a ni le credential helper, ni FACTORY_TOKEN, ni le jeton complet. \
		avec_git_cred() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0='!gh auth git-credential' "$$@" ; } ; \
		auth="Authorization: Basic $$(printf 'x-access-token:%s' "$$GH_TOKEN" | base64 -w0)" ; \
		if ! GIT_TERMINAL_PROMPT=0 git -c "http.https://github.com/.extraheader=$$auth" -C "$(CURDIR)" fetch -q origin "$$FACTORY_STAGING" 2>/dev/null ; then \
			echo "$(FACTORY_CYAN)— fetch de origin/$$FACTORY_STAGING impossible : la boucle tourne avec l'outillage qu'elle a. —$(FACTORY_RST)" ; \
		elif ! git -C "$(CURDIR)" merge --ff-only -q "origin/$$FACTORY_STAGING" 2>/dev/null ; then \
			echo "$(FACTORY_CYAN)— la branche de travail locale ne peut pas avancer jusqu'à origin/$$FACTORY_STAGING (arbre sale, ou divergence). La boucle tourne avec l'outillage qu'elle a. —$(FACTORY_RST)" ; \
		fi ; \
		# L'OUTILLAGE AUSSI DOIT ETRE FRAIS. La branche de travail vient \
		# d'avancer ; si l'usine vit dans un submodule, son pointeur a peut-etre \
		# bouge avec. Sans cette ligne on recree le defaut du 2 aout (outillage \
		# perime qui a l'air de marcher) par une nouvelle porte. \
		# SAUF SI QUELQU'UN Y TRAVAILLE : sur un poste, un submodule dont HEAD est \
		# sur une BRANCHE est l'arbre d'un humain ; le re-detacher a chaque tour \
		# changerait son arbre sous ses pieds sans un mot. Une usine a toujours \
		# son submodule detache sur le pointeur. \
		if git -C "$(CURDIR)/tools/factory" symbolic-ref -q HEAD >/dev/null 2>&1; then \
			echo "$(FACTORY_CYAN)— tools/factory est sur une branche (un humain y travaille) : le pointeur n'est pas rafraîchi ce tour-ci. —$(FACTORY_RST)" ; \
		else \
			git -c "http.https://github.com/.extraheader=$$auth" -C "$(CURDIR)" submodule update --init --quiet 2>/dev/null || true ; \
		fi ; \
		# `|| true` SAUF SUR LE 3. Le ménage a le droit de rater — un DNS qui \
		# bafouille, une carte qui a bougé sous le script — et un tour ne meurt \
		# pas pour ça. Mais 3 ne veut pas dire « ça a raté », il veut dire « la \
		# configuration est cassée, arrête-toi » : c'est le code que \
		# `conf_require` et `branches_require` rendent. Avalé par un `|| true`, \
		# un FACTORY_STAGING mal écrit ferait tourner la boucle en silence, sans \
		# jamais intégrer, débloquer ni nettoyer, avec l'air de marcher. \
		hk=0 ; bash "$(FACTORY_BIN)/wt-cleanup.sh" || hk=$$? ; \
		[ "$$hk" != 3 ] || { echo "$(FACTORY_CYAN)— wt-cleanup : configuration cassée (voir ci-dessus). Arrêt. —$(FACTORY_RST)" ; exit 3 ; } ; \
		hk=0 ; bash "$(FACTORY_BIN)/gh-unblock.sh" || hk=$$? ; \
		[ "$$hk" != 3 ] || { echo "$(FACTORY_CYAN)— gh-unblock : configuration cassée (voir ci-dessus). Arrêt. —$(FACTORY_RST)" ; exit 3 ; } ; \
		# FACTORY_SECURITY_FEATURE (la feature permanente des cartes d'alerte) \
		# est résolue ICI, par conf_get, comme les labels : le Python ne lit \
		# pas factory.conf. Vide = chaque alerte devient sa propre mini-feature, \
		# et le triage le dit à chaque tour. \
		command -v python3 >/dev/null && \
		  PRIO="$$(label_get priority)" BUSY="$$(label_get busy)" \
		  DONE="$$(label_get done)" STAGED="$$(label_get staged)" \
		  BLOCKED="$$(label_get blocked)" HUMAN="$$(label_get human)" \
		  FACTORY_SECURITY_FEATURE="$$(conf_get FACTORY_SECURITY_FEATURE)" \
		  python3 "$(FACTORY_BIN)/gh-security-triage.py" || true ; \
		# LE MÉNAGE DU CONSOMMATEUR, s'il en a. Un projet a des alertes que \
		# l'usine ne connaît pas — les erreurs de production de SON schéma \
		# d'événements, ses files à lui — et qui doivent devenir des cartes au \
		# même moment que les autres. Sans ce crochet il n'a que deux mauvaises \
		# options : les câbler hors de la boucle, où elles ne tournent jamais, \
		# ou forker `factory.mk`. Comme le reste du ménage, un échec ne tue pas \
		# le tour : `|| true`. \
		[ -x "$(CURDIR)/tools/factory-hooks/housekeeping" ] \
		  && "$(CURDIR)/tools/factory-hooks/housekeeping" || true ; \
		# gh-pr-attention ferme le ménage : il lit les PR de feature et écrit des \
		# cartes ; un 4 (GitHub injoignable) fait dormir le tour, un 3 l'arrête. \
		hk=0 ; bash "$(FACTORY_BIN)/gh-pr-attention.sh" || hk=$$? ; \
		if [ "$$hk" = 4 ]; then \
			echo "$(FACTORY_CYAN)— GitHub injoignable (raté passager) · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			sleep $(LOOP_SLEEP) ; continue ; \
		fi ; \
		[ "$$hk" != 3 ] || { echo "$(FACTORY_CYAN)— gh-pr-attention : configuration cassée (voir ci-dessus). Arrêt. —$(FACTORY_RST)" ; exit 3 ; } ; \
		# (b) LA SÉLECTION : UN seul appel. stdout porte le numéro (capturé), \
		# stderr l'explication (laissée filer vers le terminal). \
		issue="$$(bash "$(FACTORY_BIN)/gh-next-issue.sh")" && rc=0 || rc=$$? ; \
		case "$$rc" in \
			0) rm -f "$(CURDIR)/.omc/loop.file-vide" ;; \
			3) echo "$(FACTORY_CYAN)— sondage impossible : configuration cassée (voir ci-dessus). Arrêt. —$(FACTORY_RST)" ; exit 3 ;; \
			1) echo "$(FACTORY_CYAN)— file vide · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			   printf "%s\n" "aucune carte admissible : toute carte ouverte est livrée, bloquée, hors jalon ou en attente d'un humain (le journal du sondage dit laquelle)" > "$(CURDIR)/.omc/loop.file-vide" ; \
			   sleep $(LOOP_SLEEP) ; continue ;; \
			4) echo "$(FACTORY_CYAN)— GitHub injoignable (raté passager) · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			   sleep $(LOOP_SLEEP) ; continue ;; \
			*) echo "$(FACTORY_CYAN)— sondage : code $$rc imprévu, traité comme un raté passager · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			   sleep $(LOOP_SLEEP) ; continue ;; \
		esac ; \
		# TOUT CODE IMPREVU DORT. Un 127, un python absent, un `set -e` inattendu \
		# ne tombaient dans aucune branche, et la boucle lancait un agent YOLO \
		# sur « l'issue # » — vide — LOOP_MAX_RETRY fois. \
		case "$$issue" in ''|*[!0-9]*) echo "$(FACTORY_CYAN)— sondage : numéro illisible (« $$issue »), traité comme un raté passager —$(FACTORY_RST)" ; sleep $(LOOP_SLEEP) ; continue ;; esac ; \
		# (d, première moitié) LE RÉPERTOIRE DE TOUR (D8) : .omc/turn/<carte>/ \
		# persiste entre les tours d'une même carte — N est PAR CARTE — et il \
		# est REMIS À ZÉRO quand une carte réadmise avait été mise en \
		# needs-human : l'humain a tranché, une faille levée repart d'un tour \
		# propre. Le marqueur est posé par le skill quand il pose le label. Ce \
		# geste vient AVANT feature-up, qui dépose card.json dans le répertoire. \
		turn="$(CURDIR)/.omc/turn/$$issue" ; \
		if [ -f "$$turn/needs-human" ]; then \
			mkdir -p "$(CURDIR)/.omc/turns-done" ; \
			mv "$$turn" "$(CURDIR)/.omc/turns-done/$$issue-$$(date +%s)-needs-human" ; \
			echo "$(FACTORY_CYAN)— carte #$$issue réadmise après needs-human : tour remis à zéro, l'ancien est archivé —$(FACTORY_RST)" ; \
		fi ; \
		# (c) LA FEATURE : branche, worktree, PR — créés s'ils manquent, repris \
		# sinon. Une ligne tabulée : F, branche, worktree, base (le SHA de \
		# origin/feature/<F> maintenant), PR. Un 3 arrête (configuration, ou \
		# carte de type Feature) ; tout le reste est un raté passager qui dort. \
		fu="$$(avec_git_cred bash "$(FACTORY_BIN)/feature-up.sh" "$$issue")" && fuc=0 || fuc=$$? ; \
		case "$$fuc" in \
			0) ;; \
			1) echo "$(FACTORY_CYAN)— carte #$$issue refusée par feature-up (needs-human posé, voir la carte) · retour au sondage —$(FACTORY_RST)" ; continue ;; \
			3) echo "$(FACTORY_CYAN)— feature-up : configuration cassée ou carte #$$issue inadmissible (voir ci-dessus). Arrêt. —$(FACTORY_RST)" ; exit 3 ;; \
			*) echo "$(FACTORY_CYAN)— feature-up : raté passager (code $$fuc) · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			   sleep $(LOOP_SLEEP) ; continue ;; \
		esac ; \
		IFS="$$(printf '\t')" read -r feat branche wt base pr <<<"$$fu" ; \
		if [ -z "$$feat" ] || [ -z "$$wt" ] || [ -z "$$base" ] || [ -z "$$pr" ] || [ ! -d "$$wt" ]; then \
			echo "$(FACTORY_CYAN)— feature-up a rendu une ligne incomplète (« $$fu ») : traité comme un raté passager —$(FACTORY_RST)" ; \
			sleep $(LOOP_SLEEP) ; continue ; \
		fi ; \
		# (d, seconde moitié) LA BASE EST ÉCRITE UNE FOIS, PUIS RELUE. Sur un \
		# nouveau tour de la même carte, la branche a peut-être avancé (un \
		# tour précédent a livré une autre carte de la feature) : réécrire la \
		# base ferait relire à l'analyste de la reprise un diff qui ne \
		# contient plus ses propres commits, et turn-verify ne verrait plus la \
		# fenêtre du premier codeur. La base d'une carte est celle de son \
		# premier tour, jusqu'à la livraison ou la remise à zéro. \
		mkdir -p "$$turn" ; \
		if [ -f "$$turn/base" ]; then base="$$(cat "$$turn/base")" ; else printf '%s' "$$base" > "$$turn/base" ; fi ; \
		prompt="$(LOOP_PROMPT)" ; \
		prompt="$${prompt//@ISSUE@/"$$issue"}" ; prompt="$${prompt//@REPO@/"$$GH_REPO"}" ; \
		prompt="$${prompt//@FEATURE@/"$$feat"}" ; prompt="$${prompt//@WORKTREE@/"$$wt"}" ; \
		prompt="$${prompt//@BASE@/"$$base"}" ; prompt="$${prompt//@PR@/"$$pr"}" ; prompt="$${prompt//@ROOT@/"$(CURDIR)"}" ; \
		echo "$(FACTORY_CYAN)— issue #$$issue · feature #$$feat (feature/$$feat, PR #$$pr, base $$base) —$(FACTORY_RST)" ; \
		# LA GARDE ANTI-TOURNIQUET : une même carte reprise LOOP_MAX_RETRY fois \
		# sans avancer arrête la boucle. `$$issue` est le sujet du tour ; une \
		# carte livrée est fermée et ne revient pas, une carte refusée par la \
		# porte revient, et c'est ce compteur qui borne ses retours. \
		if [ "$$issue" = "$$last" ]; then \
			same=$$((same+1)) ; \
		else \
			last="$$issue" ; same=1 ; \
		fi ; \
		[ "$$same" -gt 1 ] || since="$$(date +%s)" ; \
		printf '%s %s %s\n' "$$last" "$$same" "$$since" > "$$retry" ; \
		if [ "$$same" -gt "$(LOOP_MAX_RETRY)" ]; then \
			printf '« %s » reprise %s fois sans avancer' "$$issue" "$(LOOP_MAX_RETRY)" > "$$halt" ; \
			echo "$(FACTORY_CYAN)— « $$issue » reprise $(LOOP_MAX_RETRY) fois sans avancer : arrêt. Regardez ce qui la bloque, puis effacez $$halt et $$retry avant de relancer. —$(FACTORY_RST)" ; \
			exit 4 ; \
		fi ; \
		# (e) L'ORCHESTRATEUR, DANS LE WORKTREE. Il y lit VERIFY.md et y lance \
		# les rôles ; les artefacts, eux, vont sous .omc/turn/<carte>/ de \
		# l'arbre principal (factory_root), jamais dans le worktree. \
		# SANS LES IDENTIFIANTS DE LA BOUCLE : `env -u` retire le credential \
		# helper et FACTORY_TOKEN, et GH_TOKEN devient le jeton RÉDUIT — l'agent \
		# et ses rôles parlent à l'API (labels, commentaires, sous-issues) et ne \
		# peuvent pas pousser. \
		# UN `pret` DÉJÀ POSÉ SAUTE L'ORCHESTRATEUR : le tour précédent a fini, \
		# c'est la livraison qui a raté (un 5xx de deliver.sh) — relancer un \
		# orchestrateur complet coûterait une équipe entière pour rejouer un \
		# push. On va droit à la porte et à la livraison. \
		if [ -f "$$turn/pret" ]; then \
			echo "$(FACTORY_CYAN)— #$$issue : pret déjà posé, l'orchestrateur n'est pas relancé ; porte puis livraison —$(FACTORY_RST)" ; \
		elif [ -n "$(VERBOSE)" ]; then \
			( cd "$$wt" && env -u FACTORY_TOKEN -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 GH_TOKEN="$$AGENT_TOKEN" $(LOOP_RUN_VERBOSE) ) || true ; \
		else \
			( cd "$$wt" && env -u FACTORY_TOKEN -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 GH_TOKEN="$$AGENT_TOKEN" $(LOOP_RUN_QUIET) ) || true ; \
		fi ; \
		# (f) AU RETOUR : LA PORTE, PUIS LA LIVRAISON — DANS L'ENVIRONNEMENT DE \
		# LA BOUCLE, JAMAIS DANS CELUI DE L'AGENT. L'orchestrateur a déjà joué \
		# turn-verify.sh avant de poser `pret` ; la boucle le REJOUE ici, avec \
		# SA configuration (le catalogue des rôles, FACTORY_REVIEW_MAX, \
		# CLAUDE_BIN…), parce qu'un orchestrateur qui aurait posé \
		# FACTORY_ROLE_RELECTEUR_SECU=haiku dans son shell verrait sa porte \
		# s'ouvrir sur un artefact que la nôtre refuse. C'est LA MOITIÉ de la \
		# garantie — la porte protège contre un orchestrateur qui NÉGLIGE ; \
		# l'autre moitié, uid distinct et artefacts signés, qui fermerait la \
		# classe adversariale à uid égal, est REPORTÉE (docs/v2-feature.md § 4, \
		# EVOL). Sans `pret`, l'orchestrateur s'est arrêté ailleurs (needs-human \
		# posé, carte de refacto carvée, prémisse fausse, ou mort) : rien de plus. \
		if [ -f "$$turn/pret" ]; then \
			vrc=0 ; bash "$(FACTORY_BIN)/turn-verify.sh" "$$issue" "$$wt" "$$base" > "$$turn/turn-verify.out" 2>&1 || vrc=$$? ; \
			cat "$$turn/turn-verify.out" ; \
			if [ "$$vrc" = 0 ]; then \
				drc=0 ; avec_git_cred bash "$(FACTORY_BIN)/deliver.sh" "$$issue" "$$wt" "$$base" || drc=$$? ; \
				case "$$drc" in \
					0) echo "$(FACTORY_CYAN)— carte #$$issue livrée sur feature/$$feat (PR #$$pr) —$(FACTORY_RST)" ;; \
					1) rm -f "$$turn/pret" ; echo "$(FACTORY_CYAN)— carte #$$issue refusée à la livraison (needs-human posé, voir la carte) —$(FACTORY_RST)" ;; \
					3) printf 'deliver.sh a rendu 3 sur #%s (configuration cassée, ou livraison impossible : voir le journal) ; pret est conservé' "$$issue" > "$$halt" ; \
					   echo "$(FACTORY_CYAN)— deliver : configuration cassée (voir ci-dessus). Arrêt ; $$halt posé — sous Restart=always, la relance s'arrêterait sinon toutes les trente secondes sur le même 3, pret étant conservé. —$(FACTORY_RST)" ; exit 3 ;; \
					*) echo "$(FACTORY_CYAN)— deliver : raté (code $$drc) · la carte #$$issue sera reprise, pret est conservé —$(FACTORY_RST)" ;; \
				esac ; \
			else \
				# LES MOTIFS SONT POSTÉS SUR LA CARTE, TELS QUELS, et `pret` est \
				# CONSOMMÉ : le tour suivant doit le regagner. La carte reste \
				# ouverte et `busy`, la sélection la reprend ; LOOP_MAX_RETRY borne. \
				rm -f "$$turn/pret" ; \
				{ printf 'La boucle a refusé le push de #%s (turn-verify.sh, code %s) :\n\n```\n' "$$issue" "$$vrc" ; cat "$$turn/turn-verify.out" ; printf '```\n' ; } > "$$turn/refus.md" ; \
				bash "$(FACTORY_BIN)/gh-comment.sh" "$$issue" "$$turn/refus.md" \
				  || echo "$(FACTORY_CYAN)— les motifs du refus n'ont pas pu être postés sur #$$issue (ils sont dans $$turn/turn-verify.out) —$(FACTORY_RST)" ; \
				echo "$(FACTORY_CYAN)— push de #$$issue refusé par turn-verify (code $$vrc) : motifs postés sur la carte, elle sera reprise —$(FACTORY_RST)" ; \
			fi ; \
		else \
			echo "$(FACTORY_CYAN)— tour de #$$issue terminé sans pret : arbitrage humain, refacto carvée, prémisse fausse, ou tour mort (voir la carte) —$(FACTORY_RST)" ; \
		fi ; \
		if stop_asked ; then break ; fi ; \
	done

## loop-stop: demande à la boucle de finir sa carte en cours, puis de s'arrêter
.PHONY: loop-stop
loop-stop:
	@mkdir -p "$(CURDIR)/.omc"
	@touch "$(CURDIR)/.omc/loop.stop"
	@echo "$(FACTORY_CYAN)— arrêt demandé : la boucle s'arrêtera après la carte en cours —$(FACTORY_RST)"

## factory-status: etat de l'usine distante (SINCE, CARDS)
.PHONY: factory-status
factory-status:
	@bash "$(FACTORY_BIN)/status.sh"

## factory-log: journal de l'usine distante (N=200 ; FOLLOW=1 en direct)
.PHONY: factory-log
factory-log:
	@bash "$(FACTORY_BIN)/factory" log $(if $(FOLLOW),-f,$(or $(N),200))

## factory-deploy: met le depot de l'usine au niveau de la branche de travail (FACTORY_STAGING)
.PHONY: factory-deploy
factory-deploy:
	@bash "$(FACTORY_BIN)/deploy.sh"

## factory-release: a blanc — les cartes que la derniere release fermerait (--apply se lance a la main)
# Pure delegation, comme ses trois voisines : revalider ici donnerait deux copies
# de la meme regle dans deux langages, qui finissent par diverger. La cible ne
# passe AUCUN argument, donc gh-release.sh tourne a blanc : fermer des cartes que
# personne ne rouvrira demande de taper `--apply` soi-meme.
# ET C'EST LA PORTE HUMAINE : la recette `loop` exporte FACTORY_IN_LOOP=1, que
# `gh-release.sh` refuse. Lancee a la main, la variable n'est pas la ; lancee par
# un agent de la boucle, elle l'est, et le script s'arrete.
.PHONY: factory-release
factory-release:
	@bash "$(FACTORY_BIN)/gh-release.sh"
