#!/usr/bin/env bash

# Don't exit on error - continue to see all output
set -x

curl -v debian.org
curl -v https://aur.archlinux.org/rpc

AUR_DEBUG=1 aur depends --pkgname chez-scheme

AUR_DEBUG=1 aur depends --pkgname chez-scheme lib32-libxpm fcitx sfwbar ydcv buku

echo "=== Debug: GH_TOKEN is: '${GH_TOKEN:0:10}...' (length: ${#GH_TOKEN})"
echo "=== Debug: GH_TOKEN is: '${INPUT_TOKEN:0:10}...' (length: ${#INPUT_TOKEN})"
echo "=== Debug: GH_TOKEN is: '${ACTION_RUNTIME_TOKEN:0:10}...' (length: ${#ACTION_RUNTIME_TOKEN})"

if [ -z "$GH_TOKEN" ]; then
    echo "ERROR: GH_TOKEN environment variable is not set!"
    exit 1
fi

export GH_REPO="$GITHUB_REPOSITORY"

# Always use the current master snapshot of the package repository. Do this at
# runtime instead of in the Dockerfile, otherwise a cached image layer can
# leave the builder with stale PKGBUILDs and missing local source files.
rm -rf /tmp/aurci2
git clone --depth 1 https://github.com/kitech/aurci2.git /tmp/aurci2

PREV_DIR="/tmp/prev_release"
mkdir -p "$PREV_DIR"
mkdir -p /local_repository

# Download previous release assets
if [ -n "$GH_TOKEN" ]; then
    echo "Downloading previous release assets..."
    # Download all assets from the release
    RELEASE_TAG="aurci2"
    gh release download "$RELEASE_TAG" -D "$PREV_DIR" 2>/dev/null || echo "No previous release found"

    # Debug: show what was downloaded
    echo "Downloaded files:"
    ls -la "$PREV_DIR/"

    if [ -f "$PREV_DIR/aurci2.db.tar.gz" ]; then
        echo "Restoring previous repository databases..."
        cp "$PREV_DIR/aurci2.db.tar.gz" /local_repository/
        cp "$PREV_DIR/aurci2.files.tar.gz" /local_repository/
    fi

    # Restore previously built packages (copy all .pkg.tar.zst files)
    # Use find instead of ls for more reliable globbing
    find "$PREV_DIR" -maxdepth 1 -name "*.pkg.tar.zst" -type f -exec cp {} /local_repository/ \;
    restored_count=$(ls /local_repository/*.pkg.tar.zst 2>/dev/null | wc -l)
    echo "Restored $restored_count packages to /local_repository"

    # List packages from previous database
    echo "Packages in local repository:"
    pacman -Sy --noconfirm 2>/dev/null || true
    pacman -Sl aurci2
fi

# Get list of packages with dependencies
echo "Fetching AUR package info..."
aur_depends_error=""
for i in 1; do
    packages_with_aur_dependencies="$(aur depends --pkgname $INPUT_PACKAGES $INPUT_MISSING_AUR_DEPENDENCIES 2>&1)"
    aur_depends_result=$?
    if [ $aur_depends_result -eq 0 ] && [ -n "$packages_with_aur_dependencies" ]; then
        break
    fi
    aur_depends_error="$packages_with_aur_dependencies"
    echo "Retry $i/3: $packages_with_aur_dependencies"
    sleep 5
done

# Check if aur depends failed (exit code or error text such as
# "AUR::Depends: target not found: <pkg>" which used to leak into the
# package list and produce bogus builds named "target"/"not")
if [ "${aur_depends_result:-1}" -ne 0 ] || \
   echo "$packages_with_aur_dependencies" | grep -qE \
       "curl:|error:|Error:|failed|500|^AUR::|target not found"; then
    echo "ERROR: Failed to fetch AUR package info: $packages_with_aur_dependencies"
    packages_with_aur_dependencies="$INPUT_MISSING_AUR_DEPENDENCIES $INPUT_PACKAGES"
    # exit 1
fi

echo "AUR package info fetched successfully: $packages_with_aur_dependencies"

echo "AUR Packages requested to install: $INPUT_PACKAGES"
echo "AUR Packages to fix missing dependencies: $INPUT_MISSING_AUR_DEPENDENCIES"
echo "AUR Packages to install (including dependencies): $packages_with_aur_dependencies"

# Sync pacman repos
pacman -Sy

# Install optional pacman dependencies
if [ -n "$INPUT_MISSING_PACMAN_DEPENDENCIES" ]; then
    echo "Additional Pacman packages to install: $INPUT_MISSING_PACMAN_DEPENDENCIES"
    pacman --noconfirm -S $INPUT_MISSING_PACMAN_DEPENDENCIES
fi

# Function to get AUR version
get_aur_version() {
    local pkg="$1"

    if [ -d "/tmp/aurci2/pkgrepos/$pkg" ]; then
	result=$(cd /tmp/aurci2/pkgrepos/$pkg && makepkg --printsrcinfo|grep pkgver|awk '{print $3}')
	pkgrel=$(cd /tmp/aurci2/pkgrepos/$pkg && makepkg --printsrcinfo|grep pkgrel|awk '{print $3}')
	if [ -n "$result" ]; then
	    result="${result}-${pkgrel}"
	    echo "$result"
	    return 0
	fi
    else
	local result=$(curl -s "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$pkg" | grep -oP '"Version":"\K[^"]+' | head -1)
	if [ -n "$result" ]; then
            echo "$result"
            return 0
	fi
    fi
    echo ""
}

# Determine which packages need building
echo "Checking for package updates..."

# Get versions from previous release packages
get_prev_version() {
    local pkg="$1"
    # Find package in previous release directory
    local prev_pkg=$(ls "$PREV_DIR"/${pkg}-*.pkg.tar.zst 2>/dev/null | head -1)
    if [ -n "$prev_pkg" ]; then
        # Extract version from filename like pkgname-version-arch.pkg.tar.zst
        basename "$prev_pkg" | sed "s/^${pkg}-//" | sed 's/-x86_64.*$//' | sed 's/-any.*$//' || echo ""
    fi
}

packages_to_build=""
for pkg in $packages_with_aur_dependencies; do
    aur_version=$(get_aur_version "$pkg")
    prev_version=$(get_prev_version "$pkg")

    if [ -z "$prev_version" ]; then
        echo "  $pkg: not in previous release, building"
        packages_to_build="$packages_to_build $pkg"
    elif [ "$(printf %s "$aur_version" | tr ':' '.')" != "$prev_version" ]; then
        echo "  $pkg: $prev_version -> $aur_version (needs update)"
        packages_to_build="$packages_to_build $pkg"
	# fix below detect exist with ${pkg}-*.pkg.tar.zst
	rm -fv /tmp/prev_release/${pkg}-${prev_version:0:3}*.pkg.tar.zst
	rm -fv /local_repository/${pkg}-${prev_version:0:3}*.pkg.tar.zst
    else
        echo "  $pkg: $aur_version (skip, no change)"
    fi
done
packages_to_build="${packages_to_build# }"

if [ -n "$packages_to_build" ]; then
    echo "Building packages: $packages_to_build"

    for pkg in $packages_to_build; do
        cd /tmp

        # Check if the exact target version already exists from previous release
        target_version=$(get_aur_version "$pkg")
        existing_pkg=$(ls /local_repository/${pkg}-$(printf %s "$target_version" | tr ':' '.')-*.pkg.tar.zst 2>/dev/null | head -1)

        if [ -n "$existing_pkg" ]; then
            echo "Package $pkg already exists from previous release, skipping build"
            continue
        fi

        echo "Building $pkg..."

	if [ -d "/tmp/aurci2/pkgrepos/$pkg" ]; then
	    cp -a /tmp/aurci2/pkgrepos/$pkg $pkg
        elif ! sudo --user builder aur fetch "$pkg"; then
            echo "Warning: Failed to fetch $pkg, skipping"
            continue
        fi

        cd "$pkg"
        # Try to build, but don't fail if deps can't be resolved from pacman
        sudo --user builder makepkg -f --skippgpcheck --noconfirm --syncdeps 2>&1 || {
            build_failed=1
            # Check if package was actually built despite dep errors
            for pkgfile in ./*.pkg.tar.zst; do
                if [ -f "$pkgfile" ]; then
                    echo "Package built despite warnings: $pkgfile"
                    build_failed=0
                    break
                fi
            done
            if [ $build_failed -eq 1 ]; then
                echo "Warning: Build failed for $pkg"
                continue
            fi
        }

        for pkgfile in ./*.pkg.tar.zst; do
            if [ -f "$pkgfile" ]; then
                echo "Copying $pkgfile to repository..."
                cp "$pkgfile" /local_repository/
            fi
        done
    done
fi

# Sanitize package filenames for GitHub release assets: ':' is not allowed
# and gets replaced by '.' on upload, which would make the db filename and
# the actual asset name (pacman download URL) diverge. Rename before repo-add.
for _f in /local_repository/*:*.pkg.tar.zst; do
    if [ -e "$_f" ]; then
        _g="$(printf %s "$_f" | tr ':' '.')"
        echo "Sanitizing asset name: $(basename "$_f") -> $(basename "$_g")"
        mv -v "$_f" "$_g"
    fi
done
unset _f _g

# Reconcile the database with every package file in /local_repository.
# Skipped packages ("skip, no change") are never repo-add'ed, so a package
# missing from a previously restored db (e.g. zenoh-c 1.10.2-1) would stay
# missing forever. Sorting by version before a single repo-add call makes the
# newest version win and prunes stale entries (aurutils 20.5.8 vs 23-1).
echo "Reconciling database with all local packages..."
mapfile -t _all_pkgs < <(ls -1 /local_repository/*.pkg.tar.zst 2>/dev/null | sort -V)
if [ ${#_all_pkgs[@]} -gt 0 ]; then
    repo-add /local_repository/aurci2.db.tar.gz "${_all_pkgs[@]}"
else
    echo "WARNING: no package files found in /local_repository"
fi

# Upload to release
if [ -n "$GH_TOKEN" ]; then
    echo "Uploading to release..."
    cd /local_repository

    if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
        # 已有资产：按 sha256 digest 判断内容是否真的没变。
        # 不能只按文件名判重——同名包可能被重新构建（新 checksum），
        # 跳过上传会让 release 保留旧包、而 db 记录新 checksum，
        # 最终 pacman -S 报 "invalid or corrupted package (checksum)"。
        declare -A _digest=()
        while IFS=$'\t' read -r _n _d; do
            [ -n "$_n" ] && _digest["$_n"]="$_d"
        done < <(gh api "repos/${GH_REPO}/releases/tags/${RELEASE_TAG}" \
            --jq '.assets[] | [.name, (.digest // "")] | @tsv' 2>/dev/null)

        _upload_pkgs=()
        for f in *.pkg.tar.zst; do
            [ -f "$f" ] || continue
            _local_digest="sha256:$(sha256sum "$f" | awk '{print $1}')"
            if [ -n "${_digest[$f]:-}" ] && [ "${_digest[$f]}" = "$_local_digest" ]; then
                echo "  Unchanged on release, skipping: $f"
            else
                echo "  New/changed package: $f"
                _upload_pkgs+=("$f")
            fi
        done

        # 数据库每轮必变，必须覆盖
        echo "Updating release..."
        if [ ${#_upload_pkgs[@]} -gt 0 ]; then
            gh release upload "$RELEASE_TAG" "${_upload_pkgs[@]}" --clobber || {
                echo "ERROR: failed to upload new packages"; exit 1; }
        fi
        gh release upload "$RELEASE_TAG" aurci2.db.tar.gz aurci2.files.tar.gz --clobber || {
            echo "ERROR: failed to upload repository databases"; exit 1; }
        unset _digest _upload_pkgs _n _d _local_digest
    else
        echo "No existing release found, skipping upload"
    fi
fi

# Move repository to workspace
if [ -n "$GITHUB_WORKSPACE" ]; then
    rm -f /local_repository/*.old
    echo "Moving repository to github workspace"
    cp /local_repository/*.pkg.tar.zst "$GITHUB_WORKSPACE/" 2>/dev/null || true
    cp /local_repository/aurci2.db.tar.gz "$GITHUB_WORKSPACE/"
    cp /local_repository/aurci2.files.tar.gz "$GITHUB_WORKSPACE/"

    cd "$GITHUB_WORKSPACE"
    rm -f aurci2.db aurci2.files
    cp aurci2.db.tar.gz aurci2.db
    cp aurci2.files.tar.gz aurci2.files
else
    echo "No github workspace known (GITHUB_WORKSPACE is unset)."
fi
