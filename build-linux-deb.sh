#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Moonfin"
APP_ID="org.moonfin.linux"
APP_ICON="$REPO_ROOT/assets/icons/moonfin.png"
BUILD_DIR="$REPO_ROOT/build/linux/release/bundle"
TEMP_DIR="$REPO_ROOT/build/linux/temp"

# 固定x86_64 -> deb amd64，移除arm64相关分支
get_artifact_platform() {
  printf '%s\n' "Linux"
}

PLATFORM_TAG="$(get_artifact_platform)"

get_deb_architecture() {
  printf '%s\n' "amd64"
}

resolve_flutter() {
  if [ -n "${FLUTTER_BIN:-}" ] && [ -x "$FLUTTER_BIN" ]; then
    printf '%s\n' "$FLUTTER_BIN"
    return 0
  fi

  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi

  local candidates=(
    "$HOME/flutter/bin/flutter"
    "$HOME/Documents/flutter/bin/flutter"
    "$HOME/snap/flutter/common/flutter/bin/flutter"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Error: Flutter not found. Add flutter to PATH or set FLUTTER_BIN to the full flutter executable path." >&2
  exit 1
}

get_app_version() {
  grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version:[[:space:]]*//' | cut -d'+' -f1 | tr -d '[:space:]'
}

resolve_mpv_package_name() {
  if command -v apt-cache >/dev/null 2>&1; then
    if apt-cache show libmpv2 >/dev/null 2>&1; then
      printf '%s\n' "libmpv2"
      return 0
    fi
    if apt-cache show libmpv1 >/dev/null 2>&1; then
      printf '%s\n' "libmpv1"
      return 0
    fi
  fi
  printf '%s\n' "libmpv1"
}

resolve_build_dir() {
  local candidates=(
    "$REPO_ROOT/build/linux/x64/release/bundle"
    "$REPO_ROOT/build/linux/release/bundle"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -d "$candidate" ] && [ -f "$candidate/moonfin" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Error: Linux bundle directory not found after Flutter build." >&2
  echo "Checked:" >&2
  for candidate in "${candidates[@]}"; do
    echo "  - $candidate" >&2
  done
  exit 1
}

resolve_shared_lib() {
  local soname="$1"

  if command -v dpkg-query >/dev/null 2>&1; then
    local pkg_candidates=()
    case "$soname" in
      libmpv.so.2) pkg_candidates=("libmpv2" "libmpv1") ;;
      libmpv.so.1) pkg_candidates=("libmpv1" "libmpv2") ;;
      libmpv.so) pkg_candidates=("libmpv-dev" "libmpv2" "libmpv1") ;;
      libsecret-1.so.0) pkg_candidates=("libsecret-1-0") ;;
      libsqlite3.so.0) pkg_candidates=("libsqlite3-0") ;;
      libwebkit2gtk-4.1.so.0) pkg_candidates=("libwebkit2gtk-4.1-0") ;;
      libwebkit2gtk-4.0.so.37) pkg_candidates=("libwebkit2gtk-4.0-37") ;;
    esac

    local dpkg_pkg
    for dpkg_pkg in "${pkg_candidates[@]:-}"; do
      local pkg_path
      pkg_path="$(dpkg-query -L "$dpkg_pkg" 2>/dev/null | awk -v s="$soname" 'index($0, "/" s) {print; exit}')"
      if [ -n "$pkg_path" ] && [ -f "$pkg_path" ]; then
        printf '%s\n' "$pkg_path"
        return 0
      fi
    done
  fi

  if command -v ldconfig >/dev/null 2>&1; then
    local resolved
    while IFS= read -r resolved; do
      [ -z "$resolved" ] && continue
      [ ! -f "$resolved" ] && continue
      case "$resolved" in
        /usr/local/*)
          continue
          ;;
      esac
      printf '%s\n' "$resolved"
      return 0
    done < <(ldconfig -p 2>/dev/null | awk -v name="$soname" '$1 == name {print $NF}')
  fi

  local candidate
  for candidate in \
    "/usr/lib/$soname" \
    "/usr/lib64/$soname" \
    "/lib/$soname" \
    "/lib64/$soname" \
    "/usr/lib/x86_64-linux-gnu/$soname"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v brew >/dev/null 2>&1; then
    candidate="$(brew --prefix 2>/dev/null)/lib/$soname"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

runtime_seed_libs() {
  local seed_libs=""

  local libmpv_path=""
  local mpv_soname
  for mpv_soname in libmpv.so.2 libmpv.so.1 libmpv.so; do
    if libmpv_path="$(resolve_shared_lib "$mpv_soname")"; then
      break
    fi
  done
  if [ -z "$libmpv_path" ]; then
    echo "Error: could not resolve libmpv (.so.2 or .so.1). Install libmpv2 (preferred) or libmpv1 on the build host." >&2
    return 1
  fi
  seed_libs="$libmpv_path"

  local libsecret_path
  if ! libsecret_path="$(resolve_shared_lib libsecret-1.so.0)"; then
    echo "Error: could not resolve libsecret-1.so.0. Install libsecret-1-0 on the build host." >&2
    return 1
  fi
  seed_libs="$seed_libs"$'\n'"$libsecret_path"

  local libsqlite3_path
  if ! libsqlite3_path="$(resolve_shared_lib libsqlite3.so.0)"; then
    echo "Error: could not resolve libsqlite3.so.0. Install libsqlite3-0 on the build host." >&2
    return 1
  fi
  seed_libs="$seed_libs"$'\n'"$libsqlite3_path"

  local webkit_path=""
  local webkit_soname
  for webkit_soname in libwebkit2gtk-4.1.so.0 libwebkit2gtk-4.0.so.37; do
    if webkit_path="$(resolve_shared_lib "$webkit_soname")"; then
      break
    fi
  done
  if [ -z "$webkit_path" ]; then
    echo "Error: could not resolve WebKitGTK runtime library (4.1 or 4.0). Install libwebkit2gtk-4.1-0 or libwebkit2gtk-4.0-37 on the build host." >&2
    return 1
  fi
  seed_libs="$seed_libs"$'\n'"$webkit_path"

  local harfbuzz_icu_path
  if harfbuzz_icu_path="$(resolve_shared_lib libharfbuzz-icu.so.0)"; then
    seed_libs="$seed_libs"$'\n'"$harfbuzz_icu_path"
  else
    echo "Warning: libharfbuzz-icu.so.0 not found on build host; AppImage may fail on distros lacking it." >&2
  fi

  printf '%s\n' "$seed_libs" | grep -v '^$' || true
}

ensure_sqlite_unversioned_link() {
  local dest_lib="$1"
  mkdir -p "$dest_lib"

  if [ -e "$dest_lib/libsqlite3.so" ]; then
    return 0
  fi

  local sqlite_real
  sqlite_real="$(find "$dest_lib" -maxdepth 1 -type f -name 'libsqlite3.so.*' | sort -V | tail -n1 || true)"
  if [ -z "$sqlite_real" ]; then
    return 0
  fi

  ln -sf "$(basename "$sqlite_real")" "$dest_lib/libsqlite3.so"
}

ensure_mpv_compat_symlinks() {
  local dest_lib="$1"

  local mpv_real
  mpv_real="$(find "$dest_lib" -maxdepth 1 -name 'libmpv.so.*' ! -type l 2>/dev/null | sort -V | tail -n1 || true)"
  [ -z "$mpv_real" ] && return 0

  local base
  base="$(basename "$mpv_real")"

  for alt in libmpv.so.1 libmpv.so.2 libmpv.so; do
    if [ ! -e "$dest_lib/$alt" ]; then
      ln -sf "$base" "$dest_lib/$alt" || return 1
    fi
  done
  return 0
}

collect_transitive_libs() {
  local seed_libs="$1"
  local all_deps=""

  while IFS= read -r seed; do
    [ -z "$seed" ] && continue
    [ ! -f "$seed" ] && continue

    local deps
    deps="$(ldd "$seed" 2>/dev/null | grep -oP '=> \K/[^ ]+' || true)"
    local abs_deps
    abs_deps="$(ldd "$seed" 2>/dev/null | grep -oP '^\s*\K/\S+(?=\s+\(0x)' || true)"
    all_deps="$(printf '%s\n%s\n%s\n%s' "$all_deps" "$deps" "$abs_deps" "$seed")"
  done <<< "$seed_libs"

  printf '%s\n' "$all_deps" | sort -u | grep -v '^$' || true
}

runtime_skip_pattern() {
  local skip='linux-vdso|ld-linux|libc[.]so|libm[.]so|libpthread|libdl[.]so|librt[.]so'
  skip="$skip"'|libstdc[+][+]|libgcc_s'
  skip="$skip"'|libX[a-z]|libxcb|libxkb|libxshmfence|libICE|libSM'
  skip="$skip"'|libwayland|libffi|libpcre'
  skip="$skip"'|libGL[.]so|libGLX|libGLdispatch|libGLESv|libEGL|libOpenGL'
  skip="$skip"'|libdrm|libgbm'
  skip="$skip"'|libglib|libgobject|libgio|libgmodule|libgthread'
  skip="$skip"'|libpulse|libdbus|libasound|libsndfile|libpipewire|libspa|libjack'
  skip="$skip"'|libfontconfig|libfreetype|libharfbuzz|libcairo|libpango|libpixman'
  skip="$skip"'|libatk|libgdk|libgtk|libepoxy|libgdk_pixbuf|librsvg'
  skip="$skip"'|libmount|libblkid|libuuid|libresolv|libnss3|libnssutil'
  skip="$skip"'|libsystemd'
  skip="$skip"'|libssl[.]so|libcrypto[.]so'
  printf '%s\n' "$skip"
}

fix_absolute_needed() {
  local dest_lib="$1"

  if ! command -v patchelf >/dev/null 2>&1; then
    echo "Warning: patchelf not found; absolute DT_NEEDED paths were not rewritten." >&2
    return 0
  fi

  local lib abs base
  for lib in "$dest_lib"/*.so*; do
    [ -f "$lib" ] || continue
    [ -L "$lib" ] && continue
    while IFS= read -r abs; do
      [ -z "$abs" ] && continue
      base="$(basename "$abs")"
      chmod u+w "$lib" 2>/dev/null || true
      patchelf --replace-needed "$abs" "$base" "$lib" 2>/dev/null || true
      if [ ! -e "$dest_lib/$base" ] && [ -f "$abs" ]; then
        cp -L "$abs" "$dest_lib/$base"
      fi
    done < <(readelf -d "$lib" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(\/[^]]*\)\].*/\1/p')
  done
}

copy_runtime_libs() {
  local dest_lib="$1"
  local lib_paths="$2"
  local skip_pattern="$3"

  mkdir -p "$dest_lib"

  local count=0
  while IFS= read -r lib_path; do
    [ -z "$lib_path" ] && continue
    [ ! -f "$lib_path" ] && continue

    local lib_name
    lib_name="$(basename "$lib_path")"
    if [[ ! "$lib_name" =~ ^libXpresent[.]so ]] && [[ ! "$lib_name" =~ ^libharfbuzz-icu[.]so ]]; then
      [[ "$lib_name" =~ $skip_pattern ]] && continue
    fi

    local real_path
    real_path="$(readlink -f "$lib_path")"
    [ -f "$real_path" ] || continue

    local real_name
    real_name="$(basename "$real_path")"

    if [ ! -f "$dest_lib/$real_name" ]; then
      cp -L "$real_path" "$dest_lib/$real_name" || return 1
      count=$((count + 1))
    fi

    if [ "$real_name" != "$lib_name" ] && [ ! -e "$dest_lib/$lib_name" ]; then
      ln -sf "$real_name" "$dest_lib/$lib_name" || return 1
    fi

    local soname
    soname="$(readelf -d "$real_path" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -n1)"
    if [ -n "$soname" ] && [ "$soname" != "$real_name" ] && [ ! -e "$dest_lib/$soname" ]; then
      ln -sf "$real_name" "$dest_lib/$soname" || return 1
    fi
  done <<< "$lib_paths"

  printf '%s\n' "$count"
}

inject_linux_runtime_libs() {
  local bundle_dir="$1"

  local seed_libs
  seed_libs="$(runtime_seed_libs)"
  if [ -z "$seed_libs" ]; then
    echo "Warning: Could not resolve runtime seed libraries on this build host." >&2
    return 1
  fi

  local all_deps
  all_deps="$(collect_transitive_libs "$seed_libs")"

  local skip
  skip="$(runtime_skip_pattern)"

  local bundled_count
  if ! bundled_count="$(copy_runtime_libs "$bundle_dir/lib" "$all_deps" "$skip")"; then
    echo "Error: could not copy runtime libraries into $bundle_dir/lib." >&2
    return 1
  fi
  fix_absolute_needed "$bundle_dir/lib" || return 1
  ensure_sqlite_unversioned_link "$bundle_dir/lib" || return 1
  ensure_mpv_compat_symlinks "$bundle_dir/lib" || return 1
  echo "Bundled $bundled_count runtime libraries for deb"

  verify_host_dependencies "$bundle_dir"
}

host_dependencies() {
  local bundle_dir="$1"
  local file
  for file in "$bundle_dir"/* "$bundle_dir"/lib/*.so*; do
    [ -f "$file" ] || continue
    [ -L "$file" ] && continue
    readelf -d "$file" 2>/dev/null |
      sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p'
  done | sort -u | while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$bundle_dir/lib/$name" ] && continue
    printf '%s\n' "$name"
  done
}

verify_host_dependencies() {
  local bundle_dir="$1"
  local skip deps unexpected=""

  if ! command -v readelf >/dev/null 2>&1; then
    echo "Warning: readelf not found, host dependencies were not checked." >&2
    return 0
  fi

  skip="$(runtime_skip_pattern)"
  deps="$(host_dependencies "$bundle_dir")"

  echo "Bundle expects these from the host:"
  printf '  %s\n' $deps

  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [[ "$name" =~ $skip ]] && continue
    [ "$name" = libjvm.so ] && continue
    unexpected="${unexpected}  ${name}"$'\n'
  done <<< "$deps"

  if [ -n "$unexpected" ]; then
    echo "Error: these are neither bundled nor listed as system provided:" >&2
    printf '%s' "$unexpected" >&2
    echo "Bundle them, or add them to runtime_skip_pattern if every distro has them." >&2
    return 1
  fi
}

create_desktop_file() {
  local dest="$1"
  local version="${2:-}"
  mkdir -p "$dest"
  cat > "$dest/${APP_ID}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Moonfin
Exec=moonfin %U
Icon=${APP_ID}
Categories=AudioVideo;Video;
Comment=Jellyfin & Emby media client
Terminal=false
StartupWMClass=${APP_ID}
MimeType=x-scheme-handler/moonfin;
EOF
  if [ -n "$version" ]; then
    echo "X-AppImage-Version=${version}" >> "$dest/${APP_ID}.desktop"
  fi
}

create_metainfo_file() {
  local dest="$1"
  local version="$2"

  mkdir -p "$dest"
  cat > "$dest/${APP_ID}.metainfo.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>${APP_ID}</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>GPL-3.0-or-later</project_license>
  <name>Moonfin</name>
  <developer_name>Moonfin Team</developer_name>
  <summary>Jellyfin &amp; Emby media client</summary>
  <description>
    <p>Moonfin is a media client for Jellyfin and Emby servers, available on mobile, TV, and desktop platforms.</p>
  </description>
  <url type="homepage">https://moonfin.app/</url>
  <launchable type="desktop-id">${APP_ID}.desktop</launchable>
  <releases>
    <release version="${version}" date="$(date '+%Y-%m-%d')"/>
  </releases>
  <content_rating type="oars-1.1"/>
</component>
EOF
}

icon_warning_shown=""

copy_icon() {
  local dest="$1"
  if [ ! -f "$APP_ICON" ]; then
    if [ -z "$icon_warning_shown" ]; then
      icon_warning_shown=1
      echo "Warning: app icon missing at $APP_ICON, packages will show a placeholder." >&2
    fi
    return
  fi
  mkdir -p "$dest"
  cp "$APP_ICON" "$dest/${APP_ID}.png"
}

install_icons() {
  local share_dir="$1"
  copy_icon "$share_dir/icons/hicolor/512x512/apps"
  copy_icon "$share_dir/pixmaps"
}

build_flutter_binary() {
  echo "Building Flutter release binary for Linux x64..."
  local flutter_bin
  flutter_bin="$(resolve_flutter)"
  cd "$REPO_ROOT"

  local attempt=1 max_attempts=3
  while true; do
    if "$flutter_bin" build linux --release --dart-define=DISTRIBUTION_CHANNEL=linux; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Error: 'flutter build linux' failed after ${max_attempts} attempts." >&2
      return 1
    fi
    echo "flutter build failed (attempt ${attempt}/${max_attempts}); purging pdfium cache and retrying..." >&2
    rm -rf "$REPO_ROOT"/build/linux/*/release/pdfium \
           "$REPO_ROOT"/build/linux/*/release/.lib/* 2>/dev/null || true
    sleep $((attempt * 10))
    attempt=$((attempt + 1))
  done
}

required_glibc_version() {
  local tree="$1" file

  command -v readelf >/dev/null 2>&1 || return 0

  for file in "$tree"/* "$tree"/lib/*.so*; do
    [ -f "$file" ] || continue
    [ -L "$file" ] && continue
    readelf --dyn-syms -W "$file" 2>/dev/null |
      awk '$7 == "UND"' |
      grep -o 'GLIBC_[0-9][0-9.]*' || true
  done | sed 's/^GLIBC_//' | sort -uV | tail -n1
}

build_deb() {
  echo "=== Building Debian Package (.deb) x64 ==="
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "Skipping .deb: dpkg-deb not found"
    return 1
  fi

  local version="$(get_app_version)"
  local deb_name="${APP_NAME}_${PLATFORM_TAG}_v${version}.deb"
  local pkg_root="$TEMP_DIR/deb/moonfin-${version}"
  local deb_arch
  deb_arch="$(get_deb_architecture)"

  rm -rf "$TEMP_DIR/deb"
  mkdir -p "$pkg_root"/{usr/bin,usr/lib/moonfin,usr/share/applications,usr/share/pixmaps,usr/share/doc/moonfin,DEBIAN}

  cp -r "$BUILD_DIR"/* "$pkg_root/usr/lib/moonfin/"

  inject_linux_runtime_libs "$pkg_root/usr/lib/moonfin"

  cat > "$pkg_root/usr/bin/moonfin" << 'EOF'
#!/bin/sh
APPDIR="/usr/lib/moonfin"
export LD_LIBRARY_PATH="$APPDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$APPDIR/moonfin" "$@"
EOF
  chmod +x "$pkg_root/usr/bin/moonfin"

  create_desktop_file "$pkg_root/usr/share/applications"
  install_icons "$pkg_root/usr/share"

  mkdir -p "$pkg_root/usr/share/metainfo"
  create_metainfo_file "$pkg_root/usr/share/metainfo" "$version"

  local depends="libgtk-3-0, libglib2.0-0, libsecret-1-0, libwebkit2gtk-4.1-0, xdg-user-dirs"
  local glibc
  glibc="$(required_glibc_version "$pkg_root/usr/lib/moonfin")"
  if [ -n "$glibc" ]; then
    depends="$depends, libc6 (>= $glibc)"
  fi
  echo "Depends: $depends"

  cat > "$pkg_root/DEBIAN/control" << EOF
Package: moonfin
Version: ${version}
Architecture: ${deb_arch}
Maintainer: Moonfin Team <support@moonfin.dev>
Installed-Size: $(du -sk "$pkg_root/usr" | cut -f1)
Depends: ${depends}
Description: Jellyfin & Emby media client
 Moonfin is a media client for Jellyfin and Emby servers,
 available on mobile, TV, and desktop platforms.
 .
 Features:
  - Browse and stream media
  - Offline downloads
  - Casting support
  - DLNA playback
Homepage: https://moonfin.app/
License: GPL-3.0-or-later
EOF

  cat > "$pkg_root/usr/share/doc/moonfin/copyright" << EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Moonfin
Upstream-Contact: https://github.com/jmshrv/Moonfin
Source: https://github.com/jmshrv/Moonfin

Files: *
Copyright: 2024-2025 Moonfin Team
License: GPL-3.0-or-later
EOF

  cd "$TEMP_DIR/deb"
  dpkg-deb --build "moonfin-${version}" "$deb_name" 2>/dev/null || true

  if [ -f "$deb_name" ]; then
    mv "$deb_name" "$REPO_ROOT/"
    echo "✓ Created: $REPO_ROOT/$deb_name"
  fi
}

main() {
  local formats="${1:-deb}"
  formats="$(printf '%s\n' "$formats" | tr '[:upper:]' '[:lower:]')"
  local version="$(get_app_version)"

  echo "======================================"
  echo "Moonfin Linux x64 Deb Builder"
  echo "Version: ${version}"
  echo "======================================"
  echo ""

  build_flutter_binary
  BUILD_DIR="$(resolve_build_dir)"
  if [ "${BUNDLE_RUNTIME_LIBS:-0}" = "1" ]; then
    inject_linux_runtime_libs "$BUILD_DIR"
  else
    echo "Skipping bundled runtime libs (set BUNDLE_RUNTIME_LIBS=1 to enable)."
  fi
  rm -rf "$TEMP_DIR"

  case "$formats" in
    deb)
      build_deb
      ;;
    *)
      cat << USAGE
Usage: $0 deb
Only deb(x64) build supported in this script.
USAGE
      exit 1
      ;;
  esac

  rm -rf "$TEMP_DIR"

  echo ""
  echo "======================================"
  echo "Build complete!"
  echo "Artifacts: $REPO_ROOT"
  ls -lh "$REPO_ROOT"/Moonfin_*.deb 2>/dev/null || echo "(no deb built)"
  echo "======================================"
}

main "$@"
