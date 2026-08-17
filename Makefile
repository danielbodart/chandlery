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
BEDROCK_VERSION ?= $(shell ./bedrock/upstream-version)

.PHONY: help base bedrock test test-base test-bedrock clean

help:
	@echo "make base        build the skeleton image"
	@echo "make bedrock     build Bedrock ($(BEDROCK_VERSION))"
	@echo "make test        build everything and run the tests"
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

test-base: base
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-server:$(TAG) test/fixtures/fake-server
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-signal-server:$(TAG) test/fixtures/fake-server-nohook
	./test/base_test.sh

test: test-base test-bedrock

clean:
	-docker rmi -f $(REGISTRY)/base:$(TAG) $(REGISTRY)/bedrock:$(TAG) \
	  $(REGISTRY)/bedrock:$(BEDROCK_VERSION) \
	  $(REGISTRY)/test-fake-server:$(TAG) $(REGISTRY)/test-signal-server:$(TAG)
