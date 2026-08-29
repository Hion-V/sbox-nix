{
  description = "Development shell for the Linux-native s&box fork";

  inputs = {
    # Matches the environment in working-shell-from-other-repo (SDK 10.0.301).
    nixpkgs.url = "github:NixOS/nixpkgs/e73de5be04e0eff4190a1432b946d469c794e7b4";
    flake-utils.url = "github:numtide/flake-utils";
    sbox-public = {
      url = "github:joshuascript/sbox-public";
      flake = false;
    };
  };

  outputs = { nixpkgs, flake-utils, sbox-public, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        revision = sbox-public.rev;

        runtimeLibs = with pkgs; [
          util-linux zlib
          libx11 libxcb
          libxcb-wm libxcb-image libxcb-keysyms libxcb-render-util
          libxkbcommon dbus fontconfig freetype glib
          libice libsm
          libjpeg_turbo pcre2 libpng
          stdenv.cc.cc.lib vulkan-loader
        ];

        steamRuntime = (pkgs.steam.override {
          extraPkgs = _: runtimeLibs;
        }).run;

        steamLauncher = pkgs.writeShellScript "sbox-steam-launch" ''
          set -euo pipefail
          native_dir="$1"
          shift
          export LD_LIBRARY_PATH="$native_dir''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

          harfbuzz_sharp="$native_dir/libHarfBuzzSharp.so"
          if [[ -e "$harfbuzz_sharp" ]]; then
            export LD_PRELOAD="$harfbuzz_sharp''${LD_PRELOAD:+:$LD_PRELOAD}"
          fi

          exec ./sbox-dev "$@"
        '';

        sboxBuildTool = pkgs.buildDotnetModule {
          pname = "sboxbuild";
          version = "1.0.0";
          src = sbox-public;
          projectFile = "engine/Tools/SboxBuild/SboxBuild.csproj";
          nugetDeps = ./deps.json;
          dotnet-sdk = pkgs.dotnet-sdk_10;
          dotnet-runtime = pkgs.dotnet-runtime_10;
          executables = [ "sboxbuild" ];
          doCheck = false;
          postPatch = ''
            substituteInPlace engine/Tools/SboxBuild/Steps/Build.cs \
              --replace-fail \
                'if ( isPublicSource )' \
                'if ( isPublicSource && Environment.GetEnvironmentVariable( "SBOX_SKIP_PUBLIC_ARTIFACTS" ) != "1" )'
          '';
        };

        sboxArtifacts = pkgs.stdenvNoCC.mkDerivation {
          pname = "sbox-public-artifacts";
          version = builtins.substring 0 7 revision;
          src = sbox-public;

          nativeBuildInputs = with pkgs; [
            cacert
            git
            sboxBuildTool
          ];

          # A fixed-output derivation may not retain references to its build
          # environment. Patch scripts later, in the normal build derivation.
          dontPatchShebangs = true;

          postPatch = ''
            git init
            git remote add origin https://github.com/joshuascript/sbox-public.git
            git fetch --no-tags origin master
            git reset --hard ${revision}
          '';

          buildPhase = ''
            runHook preBuild
            sboxbuild download-public-artifacts
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R . "$out/"
            rm -rf "$out/.git"
            runHook postInstall
          '';

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = "sha256-PZUKR6L6ORLm15FMAJv+gSGLIxWx0GaDn6A4fng/TVs=";
        };

        engineProjectFiles = [
          "engine/Sandbox-Engine.slnx"
          "engine/Launcher/Sbox/Sbox.csproj"
          "engine/Launcher/SboxDev/Sbox-Dev.csproj"
          "engine/Launcher/StandaloneTest/Sbox-Launcher.csproj"
          "engine/Launcher/SboxStandalone/Sbox-Standalone.csproj"
          "engine/Launcher/SboxServer/Sbox-Server.csproj"
          "engine/Launcher/SboxBench/SboxBench.csproj"
        ];

        engineDepsProbe = pkgs.buildDotnetModule {
          pname = "sbox-engine-deps";
          version = "1.0.0";
          src = sbox-public;
          projectFile = engineProjectFiles;
          nugetDeps = ./engine-deps.json;
          runtimeId = "linux-x64";
          dotnet-sdk = pkgs.dotnet-sdk_10;
          dotnet-runtime = pkgs.dotnet-runtime_10;
          dontBuild = true;
          dontInstall = true;
          doCheck = false;
        };

        sboxPublic = pkgs.buildDotnetModule {
          pname = "sbox-public";
          version = "0-unstable-${builtins.substring 0 7 revision}";
          src = sboxArtifacts;
          projectFile = engineProjectFiles;
          nugetDeps = ./engine-deps.json;
          runtimeId = "linux-x64";
          dotnet-sdk = pkgs.dotnet-sdk_10;
          dotnet-runtime = pkgs.dotnet-runtime_10;
          nativeBuildInputs = with pkgs; [ gcc python3 sboxBuildTool ];
          doCheck = false;

          postPatch = ''
            patchShebangs .
          '';

          buildPhase = ''
            runHook preBuild
            export PATH=${pkgs.dotnet-sdk_10}/bin:$PATH
            export DOTNET_ROOT=${pkgs.dotnet-sdk_10}/share/dotnet
            export SBOX_SKIP_PUBLIC_ARTIFACTS=1
            dotnet ${sboxBuildTool}/lib/sboxbuild/sboxbuild.dll build --config Developer
            build_date="$(date -u --date=@${toString sbox-public.lastModified} '+%d/%m/%Y %H:%M:%S')"
            printf '%s\n%s\n%s\n%s\n%s\n' \
              ${nixpkgs.lib.escapeShellArg (builtins.substring 0 7 revision)} \
              nix sbox-public nix "$build_date" > game/.version
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R . "$out/"
            runHook postInstall
          '';
        };

        sbox-dev = pkgs.writeShellApplication {
          name = "sbox-dev";
          runtimeInputs = with pkgs; [
            bash coreutils curl dotnet-sdk_10 findutils gcc git
            gnugrep gnused python3
          ];
          text = ''
            source_id=${nixpkgs.lib.escapeShellArg revision}
            store_source=${nixpkgs.lib.escapeShellArg "${sboxPublic}"}
            state_dir="''${SBOX_PUBLIC_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/sbox-public/$source_id}"

            if [[ -f "$state_dir/.nix-source-id" ]] &&
               [[ "$(< "$state_dir/.nix-source-id")" != "$source_id" ]]; then
              echo "SBOX_PUBLIC_DIR contains a different pinned revision" >&2
              exit 1
            fi

            if [[ ! -x "$state_dir/game/sbox-dev" ]] ||
               [[ ! -f "$state_dir/.nix-store-source" ]] ||
               [[ "$(< "$state_dir/.nix-store-source")" != "$store_source" ]]; then
              mkdir -p "$state_dir"
              chmod -R u+w "$state_dir" 2>/dev/null || true
              cp -R "$store_source"/. "$state_dir/"
              chmod -R u+w "$state_dir"
              printf '%s\n' "$source_id" > "$state_dir/.nix-source-id"
              printf '%s\n' "$store_source" > "$state_dir/.nix-store-source"
            fi

            game_dir="$state_dir/game"
            native_dir="$game_dir/bin/linuxsteamrt64"

            if [[ -e "$native_dir/libsteam_api64.so" ]]; then
              steam_api="$native_dir/libsteam_api64.so"
            elif [[ -e "$native_dir/steam_api64.so" ]]; then
              steam_api="$native_dir/steam_api64.so"
            elif [[ -e "$native_dir/libsteam_api.so" ]]; then
              steam_api="$native_dir/libsteam_api.so"
            else
              steam_api=""
            fi

            if [[ -n "$steam_api" ]]; then
              ln -sfn "$steam_api" "$game_dir/steam_api64.so"
              ln -sfn "$steam_api" "$game_dir/libsteam_api64.so"
            fi

            cd "$game_dir"
            exec ${steamRuntime}/bin/steam-run \
              ${steamLauncher} "$native_dir" "$@"
          '';
        };
      in
      {
        packages = {
          inherit sbox-dev;
          sbox-build-tool = sboxBuildTool;
          sbox-engine-deps = engineDepsProbe;
          sbox-artifacts = sboxArtifacts;
          sbox-public = sboxPublic;
          default = sbox-dev;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            sbox-dev
            dotnet-sdk_10
            gcc
            git
            python3
          ];

          shellHook = ''
            echo "s&box shell ready; run sbox-dev to build and launch it."
          '';
        };
      }
    );
}
