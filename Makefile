.PHONY: help doctor deps pins check build apk bundle debug linux run devices \
	install install-device install-emulator install/emulator emulator analyze test \
	logs crash clear-logs clean

PROOF_DIR ?= build/proof/$(shell date -u +%Y%m%dT%H%M%SZ)

.PHONY: proof proof-native
proof:
	python3 scripts/capture_proof.py $(PROOF_DIR)

proof-native:
	python3 scripts/capture_proof.py $(PROOF_DIR) --native

SESSION_ENV = DISPLAY="$$DISPLAY" WAYLAND_DISPLAY="$$WAYLAND_DISPLAY" \
  XDG_RUNTIME_DIR="$$XDG_RUNTIME_DIR" XDG_SESSION_TYPE="$$XDG_SESSION_TYPE" \
  XDG_CURRENT_DESKTOP="$$XDG_CURRENT_DESKTOP" QT_QPA_PLATFORM="$$QT_QPA_PLATFORM"

ifeq ($(IN_EDGE_FHS),1)
  RUN =
else ifeq ($(IN_NIX_SHELL),)
  RUN = $(SESSION_ENV) nix develop --command edge-fhs
else
  RUN = edge-fhs
endif

help:
	@echo "Edge development targets"
	@echo "  doctor            Show the pinned Flutter/Android toolchain"
	@echo "  deps              Resolve Dart dependencies"
	@echo "  check             Run the sibling-pin guard, analyzer, and serial tests"
	@echo "  apk | bundle      Build Android release artifacts"
	@echo "  debug             Build the Android debug APK"
	@echo "  install           Build and install \"Edge Dev\" (separate app id) on the one adb device; EDGE_DEVICE=<serial> to choose"
	@echo "  install-emulator  Boot/reuse an emulator, build, and install"
	@echo "  emulator          Boot/reuse an emulator without installing"
	@echo "  run               Run Edge on a Flutter device (DEVICE=<id> to choose; hot reload)"
	@echo "  proof             Capture headless tests, screenshots, and source hashes"
	@echo "  proof-native      Also capture Android JVM unit tests"

doctor:
	$(RUN) flutter doctor -v

deps: pins
	$(RUN) flutter pub get

# Run before pub get: a local pubspec_overrides.yaml deliberately fails the CI
# guard, and pub get can otherwise rewrite the tracked sibling provenance.
pins:
	$(RUN) bash .github/scripts/check_sibling_pins.sh

check: pins analyze test

build apk:
	$(RUN) flutter build apk --release

bundle:
	$(RUN) flutter build appbundle --release

debug:
	$(RUN) flutter build apk --debug

linux:
	$(RUN) flutter build linux --release

# DEVICE=<id> skips flutter's device prompt when an emulator and a phone are both attached.
run:
	$(RUN) flutter run $(if $(DEVICE),-d $(DEVICE),)

devices:
	$(RUN) flutter devices

install install-device:
	@chmod +x scripts/install-device.sh
	$(RUN) bash scripts/install-device.sh

install/emulator install-emulator:
	@chmod +x scripts/emulator-install.sh
	$(RUN) bash scripts/emulator-install.sh

emulator:
	@chmod +x scripts/emulator-install.sh
	$(RUN) bash scripts/emulator-install.sh --no-install

analyze:
	$(RUN) flutter analyze

test:
	$(RUN) flutter test --concurrency=1 --reporter=expanded

logs:
	$(RUN) adb logcat -v time OpenStrap:D Flutter:D flutter:D AndroidRuntime:E '*:S'

crash:
	$(RUN) adb logcat -b crash -d

clear-logs:
	$(RUN) adb logcat -c
	@echo "Logcat cleared."

clean:
	$(RUN) flutter clean
