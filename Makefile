# Chandlery build & test entry points.
#
# Images are tagged with the game version they bake in; VERSION defaults to
# whatever upstream currently ships, resolved by the per-game version script.
REGISTRY ?= chandlery
TAG      ?= test

.PHONY: help base test test-base clean

help:
	@echo "make base        build the skeleton image"
	@echo "make test        build everything and run the tests"
	@echo "make clean       remove the images these targets build"

base:
	docker build -t $(REGISTRY)/base:$(TAG) base

test-base: base
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-fake-server:$(TAG) test/fixtures/fake-server
	docker build --build-arg BASE=$(REGISTRY)/base:$(TAG) \
	  -t $(REGISTRY)/test-signal-server:$(TAG) test/fixtures/fake-server-nohook
	./test/base_test.sh

test: test-base

clean:
	-docker rmi -f $(REGISTRY)/base:$(TAG) \
	  $(REGISTRY)/test-fake-server:$(TAG) $(REGISTRY)/test-signal-server:$(TAG)
