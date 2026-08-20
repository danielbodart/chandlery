# Chandlery build & test entry points.
#
# Images are tagged with the game version they bake in; VERSION defaults to
# whatever upstream currently ships, resolved by the per-game version script.
REGISTRY ?= chandlery
TAG      ?= test

# The fixed mtime baked onto every game file, so an unchanged asset tree hashes
# to the same layer across versions and the registry dedupes it (images/bedrock/Dockerfile).
# A constant, not $(shell date): a build epoch that moved every run would defeat it.
SOURCE_DATE_EPOCH ?= 0

# Our packaging revision — the repo's git SHA. The image tag is
# <game-version>-<revision>, so a rebuild of the same game version with improved
# tooling ships a distinct, immutable image while the game version stays obvious.
# Recorded as org.opencontainers.image.revision; the .version label is the game.
CHANDLERY_REVISION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

# Only needed behind a TLS-terminating proxy; empty everywhere else.
EXTRA_CA ?= $(wildcard /root/.ccr/ca-bundle.crt)
BUILD_SECRETS = $(if $(EXTRA_CA),--secret id=extra-ca$(comma)src=$(EXTRA_CA),)
comma := ,

# Baked images fetch the game at build (PLAN 7.3), so the fetch credentials are
# build secrets — a file path each, none baked into the image.
#   STEAM_USERNAME + STEAM_TOKEN : the licensed Steam account and its
#     DepotDownloader account.config, for Valheim.
#   HYTALE_TOKEN : a file holding a downloader access token, e.g.
#     HYTALE_TOKEN=<(./tools/hytale-token) — minted and rotated on the host.
STEAM_USERNAME ?=
STEAM_TOKEN    ?=
HYTALE_TOKEN   ?=

# Default to whatever upstream ships right now. Pass BEDROCK_VERSION to pin.
BEDROCK_VERSION      ?= $(shell ./images/bedrock/upstream-version)
VALHEIM_BUILD_ID     ?= $(shell ./images/valheim/upstream-version)
# The manifest gid is the content address the Valheim image actually pins; the
# build id rides along as a label (PLAN 7.3).
VALHEIM_MANIFEST_GID ?= $(shell ./images/valheim/upstream-version --gid)
# The Valheim tag is the game version, which is only knowable by downloading and
# booting the server (images/valheim/game-version), so it has no cheap default — CI
# resolves it, and local builds pass it or take this placeholder.
VALHEIM_VERSION      ?= dev
# Hytale's version manifest is authenticated, so there is no unattended
# upstream-version script; pass HYTALE_VERSION to pin. The default is a
# placeholder for building and structural tests — it records, it does not fetch.
HYTALE_VERSION   ?= dev
HYTALE_PATCHLINE ?= release

.PHONY: help base bedrock valheim hytale fake-valheim fake-hytale test test-base test-bedrock test-valheim test-valheim-adapter test-hytale test-hytale-adapter clean

help:
	@echo "make base        build the skeleton image"
	@echo "make bedrock     build Bedrock ($(BEDROCK_VERSION))"
	@echo "make valheim     build Valheim ($(VALHEIM_VERSION), pass VALHEIM_VERSION to tag)"
	@echo "make hytale      build Hytale ($(HYTALE_VERSION), pass HYTALE_VERSION to pin)"
	@echo "make test        build everything and run the tests"
	@echo "make test-valheim-adapter   Valheim's adapter, without the download"
	@echo "make test-hytale-adapter    Hytale's adapter, without a token or download"
	@echo "make clean       remove the images these targets build"

base:
	docker build -t $(REGISTRY)/base:$(TAG) images/base

bedrock: base
	docker build $(BUILD_SECRETS) --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  --build-arg BEDROCK_VERSION=$(BEDROCK_VERSION) \
	  --build-arg BEDROCK_SHA256=$(BEDROCK_SHA256) \
	  --build-arg SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	  --build-arg CHANDLERY_REVISION=$(CHANDLERY_REVISION) \
	  -t $(REGISTRY)/bedrock:$(BEDROCK_VERSION) \
	  -t $(REGISTRY)/bedrock:$(BEDROCK_VERSION)-$(CHANDLERY_REVISION) \
	  -t $(REGISTRY)/bedrock:$(TAG) -f images/bedrock/Dockerfile .

test-bedrock: bedrock
	docker build --build-arg BASE=$(REGISTRY)/bedrock:$(TAG) \
	  -t $(REGISTRY)/test-raknet-pong:$(TAG) test/fixtures/raknet-pong
	BEDROCK_VERSION=$(BEDROCK_VERSION) ./test/bedrock_test.sh

valheim: base
	docker build $(BUILD_SECRETS) --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  --build-arg VALHEIM_VERSION=$(VALHEIM_VERSION) \
	  --build-arg VALHEIM_BUILD_ID=$(VALHEIM_BUILD_ID) \
	  --build-arg VALHEIM_MANIFEST_GID=$(VALHEIM_MANIFEST_GID) \
	  --build-arg STEAM_USERNAME=$(STEAM_USERNAME) \
	  --build-arg SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	  --build-arg CHANDLERY_REVISION=$(CHANDLERY_REVISION) \
	  $(if $(STEAM_TOKEN),--secret id=steam-token$(comma)src=$(STEAM_TOKEN),) \
	  -t $(REGISTRY)/valheim:$(VALHEIM_VERSION) \
	  -t $(REGISTRY)/valheim:$(VALHEIM_VERSION)-$(CHANDLERY_REVISION) \
	  -t $(REGISTRY)/valheim:$(TAG) -f images/valheim/Dockerfile .

# The adapter — prepare checks, argument assembly, stop signal, health probe —
# on a fake server, so it is testable without a 1.6 GB download.
fake-valheim: base
	docker build -f test/fixtures/fake-valheim/Dockerfile \
	  --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-valheim:$(TAG) .

test-valheim-adapter: fake-valheim
	VALHEIM_VERSION=$(VALHEIM_VERSION) VALHEIM_BUILD_ID=$(VALHEIM_BUILD_ID) VALHEIM_MANIFEST_GID=$(VALHEIM_MANIFEST_GID) \
	  ./test/valheim_test.sh

test-valheim: valheim fake-valheim
	VALHEIM_VERSION=$(VALHEIM_VERSION) VALHEIM_BUILD_ID=$(VALHEIM_BUILD_ID) VALHEIM_MANIFEST_GID=$(VALHEIM_MANIFEST_GID) \
	  ./test/valheim_test.sh

hytale: base
	docker build $(BUILD_SECRETS) --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  --build-arg HYTALE_VERSION=$(HYTALE_VERSION) \
	  --build-arg HYTALE_PATCHLINE=$(HYTALE_PATCHLINE) \
	  --build-arg HYTALE_SHA256=$(HYTALE_SHA256) \
	  --build-arg SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	  --build-arg CHANDLERY_REVISION=$(CHANDLERY_REVISION) \
	  $(if $(HYTALE_TOKEN),--secret id=hytale-token$(comma)src=$(HYTALE_TOKEN),) \
	  -t $(REGISTRY)/hytale:$(HYTALE_VERSION) \
	  -t $(REGISTRY)/hytale:$(HYTALE_VERSION)-$(CHANDLERY_REVISION) \
	  -t $(REGISTRY)/hytale:$(TAG) -f images/hytale/Dockerfile .

# The adapter — prepare checks, argument assembly, the console stop — on a fake
# server, so it is testable without a downloader token or the 3.3 GB download.
fake-hytale: base
	docker build -f test/fixtures/fake-hytale/Dockerfile \
	  --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-hytale:$(TAG) .

test-hytale-adapter: fake-hytale
	HYTALE_VERSION=$(HYTALE_VERSION) ./test/hytale_test.sh

test-hytale: hytale fake-hytale
	HYTALE_VERSION=$(HYTALE_VERSION) ./test/hytale_test.sh

test-base: base
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-server:$(TAG) test/fixtures/fake-server
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-signal-server:$(TAG) test/fixtures/fake-server-nohook
	./test/base_test.sh

test: test-base test-bedrock test-valheim test-hytale-adapter

clean:
	-docker rmi -f $(REGISTRY)/base:$(TAG) $(REGISTRY)/bedrock:$(TAG) \
	  $(REGISTRY)/bedrock:$(BEDROCK_VERSION) \
	  $(REGISTRY)/valheim:$(TAG) $(REGISTRY)/valheim:$(VALHEIM_VERSION) \
	  $(REGISTRY)/hytale:$(TAG) $(REGISTRY)/hytale:$(HYTALE_VERSION) \
	  $(REGISTRY)/test-fake-server:$(TAG) $(REGISTRY)/test-signal-server:$(TAG) \
	  $(REGISTRY)/test-raknet-pong:$(TAG) $(REGISTRY)/test-fake-valheim:$(TAG) \
	  $(REGISTRY)/test-fake-hytale:$(TAG)
