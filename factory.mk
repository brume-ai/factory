# factory.mk : la boucle d'usine, a inclure depuis le Makefile du consommateur.
#   include tools/factory/factory.mk
# Configuration : factory.conf a la racine du depot (lignes KEY = VALUE, lues
# aussi par les scripts bash), surchargable par l'environnement et la ligne de
# commande make. Extrait de Brume (Makefile, section github-loop) au SHA
# 12ac9e92 ; les commentaires dates sont les lecons payees la-bas.

# La recette de `loop` utilise des substitutions bash (`${var//motif/remplacement}`)
# pour injecter @ISSUE@/@WHY@/@PR@ dans les prompts. `/bin/sh` pointe vers `dash`
# sur Debian/Ubuntu (donc sur les runners `ubuntu-latest`) : sans cette ligne, la
# recette y echoue en « Bad substitution » alors qu'elle marche partout ou `/bin/sh`
# se trouve deja etre bash (Fedora, par exemple). GNU Make resout un SHELL sans
# slash via le PATH, donc ce nom nu suffit.
SHELL := bash

FACTORY_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
FACTORY_BIN ?= $(FACTORY_DIR)/bin

-include $(CURDIR)/factory.conf

FACTORY_TRUNK  ?= main
# Attente entre deux SONDAGES quand la file est vide. Le sondage coûte une requête
# HTTP, pas un agent : on peut donc attendre peu sans rien gaspiller. Une usine
# n'a pas à s'arrêter quand la file se vide — elle attend du travail.
LOOP_SLEEP     ?= 60
# Garde anti-tourniquet. Un agent qui rend la main sans faire avancer sa carte —
# typiquement parce qu'il a lancé une vérification EN FOND puis terminé son tour —
# la voit revenir au sondage suivant, et un agent NEUF repart de zéro. Observé le
# 2 août : quatre tours sur la même carte, quatre suites e2e complètes payées
# pour rien. Au-delà de ce compte, la boucle s'arrête et le DIT.
LOOP_MAX_RETRY ?= 3
# `make loop` lance en YOLO (--dangerously-skip-permissions, sans surveillance) sur
# Opus 5 à effort LOW, via CLAUDE_LAUNCH (surchargeable). Les prompts restent
# COURTS À DESSEIN : toute la procédure vit dans le skill `github-loop` — un fait,
# un endroit. La redire ici donnerait à l'agent deux copies concurrentes des mêmes
# ordres, ce qui est ce qui le fait argumenter et s'arrêter trop tôt. Modifiez le
# skill, pas ce prompt.
# PAS FABLE 5 : voir la lecon du 7 aout dans l'historique Brume (pot de credits
# distinct, tours qui meurent en 4 s en ressemblant a une usine occupee).
CLAUDE_LAUNCH  ?= claude --dangerously-skip-permissions --model claude-opus-5 --effort low
CODEX_LAUNCH   ?= codex exec --dangerously-bypass-approvals-and-sandbox
MAIN           ?= claude

FACTORY_BOLD := $(shell tput bold 2>/dev/null)
FACTORY_CYAN := $(shell tput setaf 6 2>/dev/null)
FACTORY_RST  := $(shell tput sgr0 2>/dev/null)

# `@ISSUE@` est substitué au lancement. Les prompts restent COURTS À DESSEIN :
# toute la procédure vit dans le skill `github-loop` — un fait, un endroit. La
# redire ici donnerait à l'agent deux copies concurrentes des mêmes ordres, ce
# qui est précisément ce qui le fait argumenter et s'arrêter trop tôt.
LOOP_PROMPT_RESUME ?= github-loop : suis le skill. Un ENVIRONNEMENT existe déjà pour la carte \#@ISSUE@ dans .worktrees/card-@ISSUE@, avec du travail inachevé (@WHY@). Tu le REPRENDS — tu ne repars pas de zéro et tu ne recrées rien : lis ce qui y est fait, réconcilie, et mène la carte au bout. Tu ne rends JAMAIS la main en attendant un résultat. Puis stop.
LOOP_PROMPT_PR ?= github-loop : suis le skill, section <Tend_A_Pull_Request>. La pull request \#@PR@ du dépôt $(GH_REPO) a un grief PRÉCIS : @WHY@. C'est CELUI-LÀ que tu traites, pas un autre. Remets-la en état, ou ferme-la en justifiant. Tu ne rends JAMAIS la main en attendant un résultat : tu bloques au premier plan jusqu'au verdict. Puis stop.
LOOP_PROMPT   ?= github-loop : suis le skill. Travaille l'issue \#@ISSUE@ du dépôt $(GH_REPO). Une seule carte, menée jusqu'à une pull request prête à relire — ou son prérequis carvé, ou marquée bloquée, ou fermée si tu prouves qu'elle n'a plus d'objet. Tu ne rends JAMAIS la main en attendant un résultat : tu bloques au premier plan jusqu'au verdict. Tu ne fermes PAS une carte que tu as travaillee — c'est le merge qui la ferme. Tu fermes en revanche une carte dont tu PROUVES qu'il n'y a rien a faire. Puis stop.
LOOP_PROMPT_CODEX ?= github-loop : suis le skill. Travaille l'issue \#@ISSUE@ du dépôt $(GH_REPO). Tu es l'agent principal et tu fais la carte de bout en bout toi-même. Une seule carte, menée jusqu'à une pull request prête à relire. Tu ne fermes PAS une carte que tu as travaillee — c'est le merge qui la ferme. Tu fermes en revanche une carte dont tu PROUVES qu'il n'y a rien a faire. Puis stop.

ifeq ($(MAIN),codex)
LOOP_MAIN_BIN    := codex
LOOP_PROMPT_TPL   = $(LOOP_PROMPT_CODEX)
LOOP_RUN_VERBOSE  = $(CODEX_LAUNCH) --json "$$prompt"
LOOP_RUN_QUIET    = $(CODEX_LAUNCH) "$$prompt"
else
LOOP_MAIN_BIN    := claude
LOOP_PROMPT_TPL   = $(LOOP_PROMPT)
LOOP_RUN_VERBOSE  = $(CLAUDE_LAUNCH) --output-format stream-json --verbose -p "$$prompt" | "$(FACTORY_BIN)/claude-stream.sh"
LOOP_RUN_QUIET    = $(CLAUDE_LAUNCH) -p "$$prompt"
endif

## loop: boucle ralph sur les issues GitHub — agent NEUF par carte (MAIN=claude|codex ; VERBOSE=1 pour suivre)
.PHONY: loop
loop:
	@command -v $(LOOP_MAIN_BIN) >/dev/null 2>&1 || { echo "$(LOOP_MAIN_BIN) CLI introuvable dans le PATH"; exit 1; }
	@[ -n "$(GH_REPO)" ] || { echo "factory.mk: GH_REPO absent (factory.conf a la racine du depot)"; exit 3; }
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
	@[ -n "$(FACTORY_GIT_NAME)" ] && [ -n "$(FACTORY_GIT_EMAIL)" ] || { echo "factory.mk: FACTORY_GIT_NAME / FACTORY_GIT_EMAIL absents (factory.conf)"; exit 3; }
	@# GARDE : la boucle ne tourne QUE depuis le tronc. Son outillage (Makefile,
	@# skills, tools/factory) est versionné avec le produit : sur une branche de
	@# carte, elle exécute la version d'AVANT le dernier correctif. Observé le
	@# 2 août — un agent avait laissé l'arbre sur `card/7`, et la boucle a tourné
	@# avec un Makefile qui ignorait `gh-unblock.sh`, donc sans résoudre aucune
	@# dépendance. Rien ne le signalait : elle avait l'air de marcher.
	@# La vraie correction est ailleurs (les agents travaillent en worktree, ils ne
	@# déplacent jamais l'arbre principal) ; cette garde attrape le jour où l'un
	@# d'eux l'oublie.
	@b="$$(git -C "$(CURDIR)" branch --show-current)" ; \
	if [ "$$b" != "$(FACTORY_TRUNK)" ]; then \
		echo "$(FACTORY_CYAN)— l'arbre est sur « $$b », pas sur « $(FACTORY_TRUNK) » : la boucle tournerait avec un outillage périmé. Revenez au tronc. —$(FACTORY_RST)" ; \
		exit 5 ; \
	fi
	@echo "$(FACTORY_BOLD)github-loop$(FACTORY_RST) — $(GH_REPO) · agent : $(LOOP_MAIN_BIN) (MAIN=$(MAIN)).$(if $(VERBOSE), streaming ON.,) 'make loop-stop' pour finir la carte puis s'arrêter · Ctrl-C pour couper net."
	@# Sentinelle laissé par un run précédent : sans cette purge, la boucle
	@# s'arrêterait après une seule carte sans que personne ne l'ait demandé.
	@mkdir -p "$(CURDIR)/.omc" && rm -f "$(CURDIR)/.omc/loop.stop"
	@# `make loop-stop` pose un sentinelle relu entre deux cartes ET après l'attente :
	@# demandé pendant les $(LOOP_SLEEP)s, un arrêt lu trop tôt ferait partir une carte
	@# de plus, en silence. Ctrl-C ne peut pas rendre ce service — le SIGINT part au
	@# groupe entier, donc l'agent meurt au milieu de sa carte ; un trap n'y change rien.
	@# `|| rc=$$?` est OBLIGATOIRE : .SHELLFLAGS porte `-e`, donc une affectation
	@# dont la substitution échoue fait sortir le shell AVANT le test du code
	@# retour. Sans lui, « file vide » (code 1) tuait la boucle au lieu de la
	@# faire dormir — exactement le contraire de ce qu'une usine doit faire.
	@# ORDRE DES PRIORITÉS, et il compte : ménage, puis ENTRETIEN DES PR, puis
	@# reprise d'un environnement inachevé, puis carte neuve.
	@# Les PR passent devant la reprise parce qu'une PR bloquée bloque TOUTE la
	@# pile : chaque carte suivante se construit sur le sommet, donc empiler sur
	@# une base en conflit produit du travail invérifiable. Le travail non commité
	@# d'un worktree, lui, ne risque rien à attendre — wt-cleanup ne touche pas un
	@# worktree sans PR, et l'agent d'entretien travaille dans le sien.
	@# Avant tout sondage, deux ménages. Détruire les environnements dont le travail
	@# a atterri : une pile abandonnée coûte 3 Go, une base, une route, et surtout
	@# UNE VOIE — le hook worktree-up du projet refuse d'en fabriquer une de trop, donc un worktree oublié
	@# empêche la carte suivante de démarrer. Le skill demande à l'agent de nettoyer
	@# en partant, mais un agent tué en route ne nettoie pas : c'est justement le cas
	@# qui laisse des restes.
	@# UN RATÉ PASSAGER NE TUE PLUS L'USINE. Les sondages rendaient 3 — « mal
	@# configuré », donc arrêt — pour un DNS qui bafouille, un HTTP/2 déchiré, une
	@# réponse coupée en plein JSON. Cinq arrêts en sept jours, sous un message qui
	@# envoyait vérifier des `GH_APP_*` parfaitement bons. Le code 4 dit « réessaie
	@# plus tard » : la boucle dort comme sur une file vide, mais elle le DIT.
	@# Le 3 garde son sens strict — un refus de l'API qu'un humain doit réparer.
	@# LA SÉCURITÉ EST DU MÉNAGE, PAS UN SÉLECTEUR DE TRAVAIL. `gh-security-triage`
	@# ne rend aucun numéro et ne lance aucun agent : il transpose les alertes des
	@# onglets Security en ISSUES, puis se tait. C'est `gh-next-issue` qui les
	@# prend ensuite, sans nouveau chemin ni nouveau prompt — elles portent
	@# `factory:priority`, donc elles passent devant. Sa place est donc ici, avec
	@# wt-cleanup et gh-unblock, et non dans la chaîne de sondage.
	@# Ces alertes ne sont dans AUCUNE file : ni `gh-next-issue` (qui lit les
	@# issues) ni `gh-pr-attention` (qui lit les PR) ne les voit. 232 Dependabot et
	@# 14 CodeQL y dormaient sans que personne ne soit envoyé.
	@# Puis : rendre à la file les cartes dont le bloqueur est FERMÉ.
	@# Une carte déclare sa dépendance en tête de corps (« Bloquée par #N ») — bon
	@# endroit, lisible et durable — mais personne ne la résolvait quand #N tombait.
	@# Le 2 août, retirer les LABELS sans retirer le TEXTE a produit pire que
	@# l'immobilisme : cinq tours d'affilée à relire « Bloquée par », vérifier que
	@# c'était vrai, et re-bloquer. Zéro ligne de code, et aucun agent en tort.
	@# Le sondage : UN seul appel. stdout porte le numéro (capturé), stderr porte
	@# l'explication (laissée filer vers le terminal). Sonder deux fois pour
	@# récupérer les deux flux exposerait à une carte qui change d'état entre les
	@# deux appels — et paierait deux requêtes pour une réponse.
	@# UN JETON PAR CARTE, frappé juste avant de lancer l'agent et exporté. Chaque
	@# appel Bash d'un agent est un shell NEUF : un `export` posé par l'agent ne
	@# survit pas à son propre outil. Faute de quoi il choisit entre deux mauvaises
	@# options, et il a fait les deux — écrire le jeton dans /tmp (un secret sur
	@# disque, oublié si le tour meurt), ou le refrapper à CHAQUE commande, une
	@# trentaine de fois sur la carte #32. Frappé ici, il est hérité par tous les
	@# shells du tour. Il vit une heure ; une carte qui dépasse voit un 401, et le
	@# skill dit alors de le refrapper.
	@# LE TRONC LOCAL AVANCE À CHAQUE TOUR, et pas seulement au démarrage. La garde
	@# ci-dessus compare le NOM de la branche à « $(FACTORY_TRUNK) » ; elle ne dit rien de sa
	@# FRAÎCHEUR. Vous mergez une PR sur GitHub, l'arbre local reste au commit
	@# d'avant, et la boucle continue à exécuter l'outillage d'AVANT le correctif —
	@# scripts de `tools/factory/` et skill `github-loop` — sans que rien ne le
	@# signale. C'est le défaut du 2 août (l'arbre laissé sur `card/7`) par une
	@# autre porte : bonne branche, contenu périmé. Les CARTES, elles, n'ont jamais
	@# souffert de ça — le skill fabrique chaque worktree depuis `origin/<base>`
	@# fraîchement fetché.
	@# `merge --ff-only` et pas `reset --hard` : `deploy.sh` peut se permettre le
	@# second parce que la VM d'usine n'a aucun travail humain, mais `make loop` se
	@# lance aussi depuis un poste, où l'arbre principal porte des modifications à
	@# quelqu'un. Un `reset --hard` les emporterait sans le dire. Le `ff-only`
	@# échoue proprement, et on dit pourquoi plutôt que de laisser un tour muet.
	@# PORTÉE EXACTE, pour ne pas croire plus que ce que ça fait : les scripts et le
	@# skill sont relus à chaque invocation, donc ils prennent effet dès ce tour-ci.
	@# Le Makefile, lui, est déjà parsé par le `make` en cours : un correctif qui le
	@# touche n'entre qu'au prochain démarrage de la boucle.
	@last="" ; same=0 ; \
	export GIT_AUTHOR_NAME="$(FACTORY_GIT_NAME)" GIT_AUTHOR_EMAIL="$(FACTORY_GIT_EMAIL)" ; \
	export GIT_COMMITTER_NAME="$(FACTORY_GIT_NAME)" GIT_COMMITTER_EMAIL="$(FACTORY_GIT_EMAIL)" ; \
	stop_asked() { \
		[ -f "$(CURDIR)/.omc/loop.stop" ] || return 1 ; \
		rm -f "$(CURDIR)/.omc/loop.stop" ; \
		echo "$(FACTORY_CYAN)— arrêt demandé : aucune nouvelle carte prise —$(FACTORY_RST)" ; \
		return 0 ; \
	} ; \
	while true; do \
		if stop_asked ; then break ; fi ; \
		if git -C "$(CURDIR)" fetch -q origin $(FACTORY_TRUNK) 2>/dev/null && \
		   ! git -C "$(CURDIR)" merge --ff-only -q origin/$(FACTORY_TRUNK) 2>/dev/null ; then \
			echo "$(FACTORY_CYAN)— le tronc local ne peut pas avancer jusqu'à origin/$(FACTORY_TRUNK) (arbre sale, ou divergence). La boucle tourne avec l'outillage qu'elle a. —$(FACTORY_RST)" ; \
		fi ; \
		# L'OUTILLAGE AUSSI DOIT ETRE FRAIS. Le tronc vient d'avancer ; si \
		# l'usine vit dans un submodule, son pointeur a peut-etre bouge avec. \
		# Sans cette ligne on recree le defaut du 2 aout (outillage perime qui \
		# a l'air de marcher) par une nouvelle porte. \
		git -C "$(CURDIR)" submodule update --init --quiet 2>/dev/null || true ; \
		GH_REPO=$(GH_REPO) bash "$(FACTORY_BIN)/wt-cleanup.sh" || true ; \
		GH_REPO=$(GH_REPO) bash "$(FACTORY_BIN)/gh-unblock.sh" || true ; \
		command -v python3 >/dev/null && GH_REPO=$(GH_REPO) python3 "$(FACTORY_BIN)/gh-security-triage.py" || true ; \
		prompt="" ; \
		pr="$$(GH_REPO=$(GH_REPO) bash "$(FACTORY_BIN)/gh-pr-attention.sh")" && prc=0 || prc=$$? ; \
		if [ "$$prc" = 4 ]; then \
			echo "$(FACTORY_CYAN)— GitHub injoignable (raté passager) · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			sleep $(LOOP_SLEEP) ; continue ; \
		fi ; \
		if [ "$$prc" != 0 ] && [ "$$prc" != 3 ]; then \
			rz="$$(bash "$(FACTORY_BIN)/wt-resume.sh")" && rzc=0 || rzc=$$? ; \
			if [ "$$rzc" = 0 ]; then \
				why="$${rz#*$$(printf '\t')}" ; issue="$${rz%%$$(printf '\t')*}" ; \
				prompt="$(LOOP_PROMPT_RESUME)" ; prompt="$${prompt//@ISSUE@/$$issue}" ; prompt="$${prompt//@WHY@/$$why}" ; \
				echo "$(FACTORY_CYAN)— reprise : carte #$$issue ($$why) —$(FACTORY_RST)" ; \
				prc=9 ; \
			fi ; \
		fi ; \
		if [ "$$prc" = 3 ]; then echo "$(FACTORY_CYAN)— sondage des PR impossible : configuration cassée. Arrêt. —$(FACTORY_RST)" ; exit 3 ; fi ; \
		if [ "$$prc" = 0 ]; then \
			why="$${pr#*$$(printf '\t')}" ; pr="$${pr%%$$(printf '\t')*}" ; \
			issue="pr$$pr" ; \
			prompt="$(LOOP_PROMPT_PR)" ; prompt="$${prompt//@PR@/$$pr}" ; prompt="$${prompt//@WHY@/$$why}" ; \
			echo "$(FACTORY_CYAN)— entretien : PR #$$pr ($$why) —$(FACTORY_RST)" ; \
		else \
		issue="$$(GH_REPO=$(GH_REPO) bash "$(FACTORY_BIN)/gh-next-issue.sh")" && rc=0 || rc=$$? ; \
		case "$$rc" in \
			3) echo "$(FACTORY_CYAN)— sondage impossible : configuration cassée (voir ci-dessus). Arrêt. —$(FACTORY_RST)" ; exit 3 ;; \
			4) echo "$(FACTORY_CYAN)— GitHub injoignable (raté passager) · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			   sleep $(LOOP_SLEEP) ; continue ;; \
			1) echo "$(FACTORY_CYAN)— file vide · nouveau sondage dans $(LOOP_SLEEP)s —$(FACTORY_RST)" ; \
			   sleep $(LOOP_SLEEP) ; continue ;; \
		esac ; \
		if [ "$$issue" = "$$last" ]; then \
			same=$$((same+1)) ; \
		else \
			last="$$issue" ; same=1 ; \
		fi ; \
		if [ "$$same" -gt "$(LOOP_MAX_RETRY)" ]; then \
			echo "$(FACTORY_CYAN)— issue #$$issue reprise $(LOOP_MAX_RETRY) fois sans avancer : arrêt. Regardez ce qui la bloque avant de relancer. —$(FACTORY_RST)" ; \
			exit 4 ; \
		fi ; \
		prompt="$(LOOP_PROMPT_TPL)" ; prompt="$${prompt//@ISSUE@/$$issue}" ; \
		echo "$(FACTORY_CYAN)— issue #$$issue —$(FACTORY_RST)" ; \
		fi ; \
		GH_TOKEN="$$(bash "$(FACTORY_BIN)/gh-app-token.sh")" || { echo "$(FACTORY_CYAN)— jeton dApp impossible à frapper : configuration cassée. Arrêt. —$(FACTORY_RST)" ; exit 3 ; } ; \
		export GH_TOKEN ; \
		if [ -n "$(VERBOSE)" ]; then \
			$(LOOP_RUN_VERBOSE) || true ; \
		else \
			$(LOOP_RUN_QUIET) || true ; \
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

## factory-deploy: met le depot de l'usine au niveau de origin/$(FACTORY_TRUNK)
.PHONY: factory-deploy
factory-deploy:
	@bash "$(FACTORY_BIN)/deploy.sh"
