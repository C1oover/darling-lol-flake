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

      darlingLolSrc = pkgs.fetchFromGitHub {
        owner = "lucannez64";
        repo = "darling-lol";
        rev = "HEAD";
        hash = "sha256-xNwX3mzaDmOVlwLaqKAKj6SUP0TBjHa10fM/tiyHeXA=";
      };

      llvmPkgs = pkgs.llvmPackages;
      clangMajor = pkgs.lib.versions.major llvmPkgs.clang-unwrapped.version;
      gccVersion = pkgs.lib.getVersion pkgs.gcc;

      clangFhsPkg = pkgs.runCommand "clang-fhs-${llvmPkgs.clang-unwrapped.version}" { } ''
        mkdir -p "$out/bin" "$out/lib/clang/${clangMajor}"
        for f in ${llvmPkgs.clang-unwrapped}/bin/*; do
          cp -a "$f" "$out/bin/$(basename "$f")"
        done
        chmod -R u+w "$out/bin"
        ln -s "${llvmPkgs.clang-unwrapped.lib}/lib/clang/${clangMajor}/include" \
          "$out/lib/clang/${clangMajor}/include"
        if [ -d "${llvmPkgs.compiler-rt}/lib" ]; then
          ln -s "${llvmPkgs.compiler-rt}/lib" "$out/lib/clang/${clangMajor}/lib"
        fi
      '';

      gcc32Support = pkgs.runCommand "gcc-32-support-${gccVersion}" { } ''
        target_lib="$out/lib/gcc/x86_64-unknown-linux-gnu/${gccVersion}/32"
        mkdir -p "$target_lib"
        for f in ${pkgs.pkgsi686Linux.gcc.cc}/lib/gcc/i686-unknown-linux-gnu/${gccVersion}/*; do
          ln -s "$f" "$target_lib/$(basename "$f")"
        done
        for f in ${pkgs.pkgsi686Linux.gcc.cc.lib}/lib/*; do
          ln -sf "$f" "$target_lib/$(basename "$f")"
        done

        target_inc="$out/include/c++/${gccVersion}/x86_64-unknown-linux-gnu"
        mkdir -p "$target_inc"
        ln -s "${pkgs.pkgsi686Linux.gcc.cc}/include/c++/${gccVersion}/i686-unknown-linux-gnu" \
          "$target_inc/32"
      '';

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

      lolInnerRunner = pkgs.writeShellScriptBin "lol-darling-inner" ''
        set -euo pipefail

        STATE_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/darling-lol"
        WORKDIR="$STATE_DIR/workdir"
        STAMP_FILE="$WORKDIR/.nix-source-stamp"
        CURRENT_SRC="${darlingLolSrc}"

        export PATH="/usr/local/bin:$PATH"
        export CC=/usr/bin/clang
        export CXX=/usr/bin/clang++
        export C_INCLUDE_PATH="/usr/include"
        export CPLUS_INCLUDE_PATH="/usr/include/c++/${gccVersion}:/usr/include/c++/${gccVersion}/x86_64-unknown-linux-gnu:/usr/include"
        export LIBRARY_PATH="/usr/lib/gcc/x86_64-unknown-linux-gnu/${gccVersion}:/usr/lib:/usr/lib32"
        export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib64:/usr/lib:/usr/lib32''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export CMAKE_POLICY_VERSION_MINIMUM=3.5

        mkdir -p "$WORKDIR" /usr/local/bin /usr/local/libexec /usr/local/lib /usr/local/share

        if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE")" != "$CURRENT_SRC" ]; then
          echo "[lol-darling] Syncing darling-lol repository to $WORKDIR..."
          rsync -r --no-g --no-o --chmod=u+rwX "$CURRENT_SRC/" "$WORKDIR/"
          echo "$CURRENT_SRC" > "$STAMP_FILE"
        fi

        cd "$WORKDIR"

        if [ ! -d "/usr/local/libexec/darling" ] || [ ! -x "/usr/local/bin/darling" ]; then
          echo "[lol-darling] Verifying Clang 64-bit & 32-bit toolchain execution..."
          TMP_TEST="$(mktemp -d)"
          printf '#include <stdio.h>\nint main(){printf("%%d\\n", __clang_major__);return 0;}\n' > "$TMP_TEST/t.c"
          printf '#include <iostream>\nint main(){std::cout << __clang_major__ << std::endl;return 0;}\n' > "$TMP_TEST/t.cpp"
          /usr/bin/clang "$TMP_TEST/t.c" -o "$TMP_TEST/tc64" && "$TMP_TEST/tc64" >/dev/null
          /usr/bin/clang++ "$TMP_TEST/t.cpp" -o "$TMP_TEST/tcpp64" && "$TMP_TEST/tcpp64" >/dev/null
          /usr/bin/clang -m32 "$TMP_TEST/t.c" -o "$TMP_TEST/tc32" && "$TMP_TEST/tc32" >/dev/null
          rm -rf "$TMP_TEST"
          echo "[lol-darling] Toolchain check passed."

          echo "[lol-darling] Building darling-lol runtime..."
          if [ ! -d "build/venv" ]; then
            python3 -m venv build/venv
          fi
          build/venv/bin/pip install --upgrade pip
          build/venv/bin/pip install -r requirements.txt

          if [ -f "build/darling-src/build/CMakeCache.txt" ] && \
             [ ! -f "build/darling-src/build/Makefile" ] && \
             [ ! -f "build/darling-src/build/build.ninja" ]; then
            echo "[lol-darling] Removing incomplete CMake cache before re-configuring..."
            rm -rf build/darling-src/build/CMakeCache.txt build/darling-src/build/CMakeFiles
          fi

          build/venv/bin/python3 scripts/configure.py --guest-user "$USER"
          ./scripts/build.sh
          cmake --install build/darling-src/build --prefix /usr/local
          ./scripts/install-runtime.sh
        fi

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
            if [ ! -d "$HOME/.darling/Applications/League of Legends.app" ] && \
               [ ! -d "$HOME/.darling/Users/Shared/Riot Games/Riot Client.app" ]; then
              REGION_LOWER="$(echo "''${RCLOL_REGION:-euw}" | tr '[:upper:]' '[:lower:]')"
              echo "[lol-darling] Riot/League not found in ~/.darling. Running installer..."
              ./scripts/installer.sh "$REGION_LOWER"
            fi

            export RCLOL_REGION="''${RCLOL_REGION:-EUW}"
            export RCLOL_LOCALE="''${RCLOL_LOCALE:-en_GB}"
            exec ./scripts/run.sh "$@"
            ;;
        esac
      '';

lolFhsEnv = pkgs.buildFHSEnv {
        name = "lol-darling-fhs";

        extraOutputsToInstall = [ "dev" "lib" ];

        extraBuildCommands = ''
          mkdir -p $out/usr/local $out/lib64
          ln -s /usr/include $out/no-such-path
        '';

        extraBwrapArgs = [
          "--bind" "$HOME/.local/share/darling-lol/usr-local" "/usr/local"
          "--ro-bind" "${pkgs.glibc}/lib/ld-linux-x86-64.so.2" "/lib64/ld-linux-x86-64.so.2"
        ];

        targetPkgs = pkgs: with pkgs; [
          # ... (keep all your existing targetPkgs from the previous version)
        ];

        multiPkgs = pkgs: with pkgs; [
          # ... (keep all your existing multiPkgs from the previous version)
        ];

        runScript = "lol-darling-inner";
      };

        targetPkgs = pkgs: with pkgs; [
          sudoShim
          lolInnerRunner
          clangFhsPkg
          gcc32Support

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
          perl
          ruby

          llvmPkgs.clang-unwrapped.lib
          llvmPkgs.compiler-rt
          llvmPkgs.lld
          llvmPkgs.llvm
          llvmPkgs.llvm.dev
          llvmPkgs.llvm.lib
          binutils-unwrapped
          gcc.cc
          gcc.cc.lib
          glibc
          glibc.dev
          linuxHeaders

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

          fuse
          fuse3
          libcap
          attr
          acl
          libffi
          libarchive
          glib
          libGL
          libGLU
          libglvnd
          mesa
          libdrm
          vulkan-loader
          vulkan-headers
          spirv-headers
          spirv-tools
          glslang
          shaderc
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
          libvorbis
          libogg
          flac
          libsndfile
          ffmpeg
          icu
          xdg-user-dirs
        ];

        multiPkgs = pkgs: with pkgs; [
          glibc
          glibc.dev
          gcc.cc.lib
          llvmPkgs.compiler-rt
          zlib
          bzip2
          xz
          openssl
          libxml2
          freetype
          fontconfig
          cairo
          libGL
          libGLU
          libglvnd
          mesa
          libdrm
          vulkan-loader
          libpulseaudio
          alsa-lib
          dbus
          systemd
          elfutils
          libbsd
          libffi
          libcap
          libx11
          libxcb
          libxext
          libxrandr
          libxcursor
          libxrender
          libxfixes
          libxi
          libxshmfence
          libxkbfile
          libxkbcommon
          libjpeg
          libpng
          libtiff
          giflib
        ];

        runScript = "lol-darling-inner";
      };

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
