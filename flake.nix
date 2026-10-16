{
  description = "Nix flake for macOS League of Legends on Linux via darling-lol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Source of lucannez64/darling-lol (scripts, patches, and upstream manifest)
      darlingLolSrc = pkgs.fetchFromGitHub {
        owner = "lucannez64";
        repo = "darling-lol";
        rev = "68f816deaf2ddcbf5cd557b0847ab32eeb0177cb";
        hash = "sha256-y0HrjyV67+ug/ExrAuli9QlxfPnjyEsIsU5fQpK/yro=";
      };

      #Inside buildFHSEnv (bubblewrap), PR_SET_NO_NEW_PRIVS blocks setuid sudo.
      # Because /usr/local is bind-mounted to a user-owned directory, a shim lets
      # darling-lol's `sudo cmake --install` and `install-runtime.sh` succeed cleanly.
      sudoShim = pkgs.writeShellScriptBin "sudo" ''
        while [ $# -gt 0 ]; do
          case "$1" in
            -E|-H|-n|-s) shift ;;
            -u|-g) shift 2 ;;
            --) shift; break ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        exec "$@"
      '';

      # Inner runner executed inside the FHS environment
      lolInnerRunner = pkgs.writeShellScriptBin "lol-darling-inner" ''
        set -euo pipefail

        STATE_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/darling-lol"
        WORKDIR="$STATE_DIR/workdir"
        STAMP_FILE="$WORKDIR/.nix-source-stamp"
        CURRENT_SRC="${darlingLolSrc}"

        export PATH="/usr/local/bin:$PATH"
        export CC=clang
        export CXX=clang++

        mkdir -p "$WORKDIR" /usr/local/bin /usr/local/libexec /usr/local/lib /usr/local/share

        # 1. Sync darling-lol scripts/patches into writable workdir
        if [ ! -f "$STAMP_FILE" ] \vert{}\vert{} [ "$(cat "$STAMP_FILE")" != "$CURRENT_SRC" ]; then
          echo "[lol-darling] Syncing darling-lol repository to $WORKDIR..."
          rsync -a --chmod=u+rwX "$CURRENT_SRC/" "$WORKDIR/"
          echo "$CURRENT_SRC" > "$STAMP_FILE"
        fi

        cd "$WORKDIR"

        # 2. First-time build & runtime installation
        if [ ! -d "/usr/local/libexec/darling" ] || [ ! -x "/usr/local/bin/darling" ]; then
          echo "[lol-darling] Building darling-lol runtime (first run - requires ~50GB free space)..."
          if [ ! -d "build/venv" ]; then
            python3 -m venv build/venv
          fi
          build/venv/bin/pip install --upgrade pip
          build/venv/bin/pip install -r requirements.txt

          build/venv/bin/python3 scripts/configure.py --guest-user "$USER"
          ./scripts/build.sh
          cmake --install build/darling-src/build --prefix /usr/local
          ./scripts/install-runtime.sh
        fi

        # 3. Subcommands for manual maintenance (`lol-darling update`, `lol-darling shell`, etc.)
        case "''${1:-run}" in
          update)
            shift
            exec ./scripts/update.sh "$@"
            ;;
          install)
            shift
            REGION="''${1:-''${RCLOL_REGION:-euw}}"
            REGION_LOWER="$(echo "$REGION" | tr '[:upper:]' '[:lower:]')"
            exec ./scripts/installer.sh "$REGION_LOWER"
            ;;
          shell)
            shift
            exec bash "$@"
            ;;
          run|*)
            # 4. Auto-run Riot installer if League/Riot Client isn't installed in ~/.darling yet
            if [ ! -d "$HOME/.darling/Applications/League of Legends.app" ] && \
               [ ! -d "$HOME/.darling/Users/Shared/Riot Games/Riot Client.app" ]; then
              REGION_LOWER="$(echo "''${RCLOL_REGION:-euw}" | tr '[:upper:]' '[:lower:]')"
              echo "[lol-darling] Riot/League not found in ~/.darling. Running installer for '$REGION_LOWER'..."
              ./scripts/installer.sh "$REGION_LOWER"
            fi

            export RCLOL_REGION="''${RCLOL_REGION:-EUW}"
            export RCLOL_LOCALE="''${RCLOL_LOCALE:-en_GB}"
            exec ./scripts/run.sh "$@"
            ;;
        esac
      '';

      # FHS environment providing all 64-bit & 32-bit headers/libs required by Darling & LoL
      lolFhsEnv = pkgs.buildFHSEnv {
        name = "lol-darling-fhs";

        targetPkgs = pkgs: with pkgs; [
          sudoShim
          lolInnerRunner

          # Core build & script tools required by darling-lol README
          bash
          coreutils
          findutils
          gnugrep
          gnused
          gawk
          diffutils
          patch
          rsync
          file
          which
          procps
          util-linux
          git
          git-lfs
          curl
          unzip
          p7zip
          cmake
          gnumake
          ninja
          pkg-config
          bison
          flex
          python3
          python3Packages.pip
          python3Packages.virtualenv
          nodejs

          # LLVM/Clang + LLD + LLVM dev files + multilib toolchain
          clang
          lld
          llvm
          libclang
          glibc_multi
          gcc_multi

          # X11 / XCB / SHM development files (Nixpkgs 26.11 top-level names)
          libx11
          libxcb
          libxext
          libxrandr
          libxcursor
          libxkbfile
          libxrender
          libxfixes
          libxi
          libxcomposite
          libxdamage
          libxshmfence
          libxkbcommon
          xcbutil
          xcbutilimage
          xcbutilkeysyms
          xcbutilrenderutil
          xcbutilwm
          xorgproto

          # Graphics, Audio, FUSE, and Darling system dependencies
          fuse
          fuse3
          libcap
          attr
          acl
          libGL
          libGLU
          libglvnd
          mesa
          vulkan-loader
          vulkan-headers
          ocl-icd
          opencl-headers
          cairo
          freetype
          fontconfig
          harfbuzz
          pango
          libtiff
          libjpeg
          giflib
          libpng
          libwebp
          libxml2
          libxslt
          sqlite
          openssl
          zlib
          bzip2
          xz
          zstd
          lz4
          libbsd
          elfutils
          libunwind
          systemd
          dbus
          libpulseaudio
          alsa-lib
          ffmpeg
          icu
          xdg-user-dirs
        ];

        multiPkgs = pkgs: with pkgs; [
          glibc
          zlib
          freetype
          fontconfig
          libGL
          libGLU
          libglvnd
          mesa
          vulkan-loader
          libpulseaudio
          alsa-lib
          libx11
          libxcb
          libxext
          libxrandr
          libxcursor
          libxrender
          libxfixes
          libxi
          libxshmfence
          libjpeg
          libpng
          libtiff
          giflib
          libxml2
          dbus
        ];

        # Bind-mount persistent user-owned directory to /usr/local inside the FHS container
        extraBwrapArgs = [
          "--dir" "/usr/local"
          "--bind" "$HOME/.local/share/darling-lol/usr-local" "/usr/local"
        ];

        runScript = "lol-darling-inner";
      };

      # Outer wrapper that ensures bind-mount targets exist before bwrap starts
      lolLauncherBin = pkgs.writeShellApplication {
        name = "lol-darling";
        runtimeInputs = [ pkgs.coreutils lolFhsEnv ];
        text = ''
          mkdir -p \
            "$HOME/.local/share/darling-lol/usr-local" \
            "$HOME/.local/share/darling-lol/workdir" \
            "$HOME/.darling"
          exec lol-darling-fhs "$@"
        '';
      };

      desktopItem = pkgs.makeDesktopItem {
        name = "lol-darling";
        desktopName = "League of Legends (Darling)";
        comment = "Play the macOS version of League of Legends on Linux via darling-lol";
        exec = "lol-darling";
        icon = "applications-games";
        categories = [ "Game" ];
        terminal = true;
      };

      lol-darling = pkgs.symlinkJoin {
        name = "lol-darling";
        paths = [
          lolLauncherBin
          desktopItem
        ];
      };

    in {
      packages.${system} = {
        inherit lol-darling;
        default = lol-darling;
      };

      overlays.default = final: prev: {
        inherit lol-darling;
      };

      nixosModules.default = {
        nixpkgs.overlays = [ self.overlays.default ];
        programs.fuse.userAllowOther = true;
      };
    };
}
