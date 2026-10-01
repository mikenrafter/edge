{
  description = "OpenStrap Edge Flutter/Android development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Match .github/workflows/{test,build}.yml exactly. Do not float Flutter:
  # newer SDKs currently break phosphor_flutter and version-sensitive imports.
  inputs.nixpkgs-flutter.url =
    "github:NixOS/nixpkgs/27dfede99da61fd1ead9d4a2fa92bc9c242e83d2";

  outputs = { self, nixpkgs, nixpkgs-flutter }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          flutterPkgs = import nixpkgs-flutter {
            inherit system;
            config.allowUnfree = true;
          };
          flutter = flutterPkgs.flutterPackages.v3_41;
          androidAbi =
            if system == "aarch64-linux" then "arm64-v8a" else "x86_64";

          androidComposition = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "11.0";
            platformToolsVersion = "37.0.1";
            buildToolsVersions = [ "35.0.0" ];
            platformVersions = [ "36" "35" "34" ];
            includeNDK = true;
            ndkVersion = "28.2.13676358";
            includeCmake = true;
            cmakeVersions = [ "3.22.1" ];
            includeEmulator = true;
            includeSystemImages = true;
            systemImageTypes = [ "default" ];
            abiVersions = [ androidAbi ];
            extraLicenses = [
              "android-sdk-license"
              "android-sdk-preview-license"
            ];
          };
          androidSdk = androidComposition.androidsdk;

          fhs = pkgs.buildFHSEnv {
            name = "edge-fhs";
            targetPkgs = p: with p; [
              flutter
              pkgs.jdk17
              androidSdk
              bashInteractive
              git
              gnumake
              python3
              unzip
              which
              zlib
              libcxx
              ncurses5
            ];
            profile = ''
              export IN_EDGE_FHS=1
              export FLUTTER_ROOT="${flutter}"
              export JAVA_HOME="${pkgs.jdk17}"
              export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
              export ANDROID_SDK_ROOT="$ANDROID_HOME"
              export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
              export ANDROID_NDK="$ANDROID_NDK_HOME"
              export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/35.0.0/aapt2"
            '';
            runScript = pkgs.writeShellScript "edge-fhs-run" ''
              if [[ $# -eq 0 ]]; then exec bash; else exec "$@"; fi
            '';
          };
        in {
          default = pkgs.mkShell {
            # platform-tools is already inside androidSdk. A second android-tools
            # package puts a different adb on PATH and confuses Flutter Doctor.
            packages = [ fhs flutter androidSdk pkgs.jdk17 pkgs.gnumake ];
            shellHook = ''
              export FLUTTER_ROOT="${flutter}"
              export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
              export ANDROID_SDK_ROOT="$ANDROID_HOME"
              export JAVA_HOME="${pkgs.jdk17}"
              export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/35.0.0/aapt2"
              ${pkgs.gnused}/bin/sed -i \
                -e 's|^flutter\.sdk=.*|flutter.sdk=${flutter}|' \
                -e 's|^sdk\.dir=.*|sdk.dir=${androidSdk}/libexec/android-sdk|' \
                android/local.properties 2>/dev/null || true
              grep -q '^flutter.sdk=' android/local.properties 2>/dev/null || \
                echo 'flutter.sdk=${flutter}' >> android/local.properties
              grep -q '^sdk.dir=' android/local.properties 2>/dev/null || \
                echo 'sdk.dir=${androidSdk}/libexec/android-sdk' >> android/local.properties
              if [[ -z "$IN_EDGE_FHS" && $- == *i* ]]; then exec edge-fhs; fi
              echo "Edge devShell (Flutter 3.41.6) — run: make help"
            '';
          };
        });
    };
}
