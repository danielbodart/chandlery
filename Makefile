# Chandlery build & test entry points.
#
# Images are tagged with the game version they bake in; VERSION defaults to
# whatever upstream currently ships, resolved by the per-game version script.
REGISTRY ?= chandlery
TAG      ?= test

# Only needed behind a TLS-terminating proxy; empty everywhere else.
EXTRA_CA ?= $(wildcard /root/.ccr/ca-bundle.crt)
BUILD_SECRETS = $(if $(EXTRA_CA),--secret id=extra-ca$(comma)src=$(EXTRA_CA),)
comma := ,

# Default to whatever upstream ships right now. Pass BEDROCK_VERSION to pin.
BEDROCK_VERSION      ?= $(shell ./bedrock/upstream-version)
VALHEIM_BUILD_ID     ?= $(shell ./valheim/upstream-version)
# The manifest gid is the content address the Valheim image actually pins; the
# build id is only the human-facing tag over it (PLAN 7.3).
VALHEIM_MANIFEST_GID ?= $(shell ./valheim/upstream-version --gid)

.PHONY: help base bedrock valheim fake-valheim test test-base test-bedrock test-valheim test-valheim-adapter clean

help:
	@echo "make base        build the skeleton image"
	@echo "make bedrock     build Bedrock ($(BEDROCK_VERSION))"
	@echo "make valheim     build Valheim ($(VALHEIM_BUILD_ID))"
	@echo "make test        build everything and run the tests"
	@echo "make test-valheim-adapter   Valheim's adapter, without the download"
	@echo "make clean       remove the images these targets build"

base:
	docker build -t $(REGISTRY)/base:$(TAG) base

bedrock: base
	docker build $(BUILD_SECRETS) --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  --build-arg BEDROCK_VERSION=$(BEDROCK_VERSION) \
	  -t $(REGISTRY)/bedrock:$(BEDROCK_VERSION) -t $(REGISTRY)/bedrock:$(TAG) bedrock

test-bedrock: bedrock
	docker build --build-arg BASE=$(REGISTRY)/bedrock:$(TAG) \
	  -t $(REGISTRY)/test-raknet-pong:$(TAG) test/fixtures/raknet-pong
	BEDROCK_VERSION=$(BEDROCK_VERSION) ./test/bedrock_test.sh

valheim: base
	docker build $(BUILD_SECRETS) --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  --build-arg VALHEIM_BUILD_ID=$(VALHEIM_BUILD_ID) \
	  --build-arg VALHEIM_MANIFEST_GID=$(VALHEIM_MANIFEST_GID) \
	  -t $(REGISTRY)/valheim:$(VALHEIM_BUILD_ID) -t $(REGISTRY)/valheim:$(TAG) valheim

# The adapter — prepare checks, argument assembly, stop signal, health probe —
# on a fake server, so it is testable without a 1 GB SteamCMD download.
fake-valheim: base
	docker build -f test/fixtures/fake-valheim/Dockerfile \
	  --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-valheim:$(TAG) .

test-valheim-adapter: fake-valheim
	VALHEIM_BUILD_ID=$(VALHEIM_BUILD_ID) VALHEIM_MANIFEST_GID=$(VALHEIM_MANIFEST_GID) \
	  ./test/valheim_test.sh

test-valheim: valheim fake-valheim
	VALHEIM_BUILD_ID=$(VALHEIM_BUILD_ID) VALHEIM_MANIFEST_GID=$(VALHEIM_MANIFEST_GID) \
	  ./test/valheim_test.sh

test-base: base
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-server:$(TAG) test/fixtures/fake-server
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-signal-server:$(TAG) test/fixtures/fake-server-nohook
	./test/base_test.sh

test: test-base test-bedrock test-valheim

clean:
	-docker rmi -f $(REGISTRY)/base:$(TAG) $(REGISTRY)/bedrock:$(TAG) \
	  $(REGISTRY)/bedrock:$(BEDROCK_VERSION) \
	  $(REGISTRY)/valheim:$(TAG) $(REGISTRY)/valheim:$(VALHEIM_BUILD_ID) \
	  $(REGISTRY)/test-fake-server:$(TAG) $(REGISTRY)/test-signal-server:$(TAG) \
	  $(REGISTRY)/test-raknet-pong:$(TAG) $(REGISTRY)/test-fake-valheim:$(TAG)
