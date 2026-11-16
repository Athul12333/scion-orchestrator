#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <repository-dir> <codename> <package.deb>" >&2
    exit 2
fi

repo_dir=$1
codename=$2
deb_file=$3

if [[ ! -d "$repo_dir/conf" ]]; then
    echo "ERROR: reprepro repository not found at $repo_dir" >&2
    exit 1
fi

if [[ ! -f "$deb_file" ]]; then
    echo "ERROR: package does not exist: $deb_file" >&2
    exit 1
fi

command -v reprepro >/dev/null 2>&1 || {
    echo "ERROR: reprepro is not installed" >&2
    exit 1
}

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "ERROR: dpkg-deb is not installed" >&2
    exit 1
}

package=$(dpkg-deb -f "$deb_file" Package)
version=$(dpkg-deb -f "$deb_file" Version)
architecture=$(dpkg-deb -f "$deb_file" Architecture)

repo_entry=$(
    cd "$repo_dir"
    reprepro list "$codename" "$package" 2>/dev/null |
        awk -v arch="$architecture" '$1 ~ ("[|]" arch ":$") {print $0; exit}'
)

if [[ -z "$repo_entry" ]]; then
    echo "PUBLISH: $package $version $architecture"
    (
        cd "$repo_dir"
        reprepro includedeb "$codename" "$deb_file"
    )
    exit 0
fi

repo_version=$(awk '{print $NF}' <<<"$repo_entry")

if dpkg --compare-versions "$repo_version" gt "$version"; then
    echo "ERROR: refusing downgrade of $package from $repo_version to $version" >&2
    exit 1
fi

if dpkg --compare-versions "$repo_version" lt "$version"; then
    echo "PUBLISH: $package $version replaces repository version $repo_version"
    (
        cd "$repo_dir"
        reprepro includedeb "$codename" "$deb_file"
    )
    exit 0
fi

repo_deb=$(
    find "$repo_dir/pool" -type f \
        -name "${package}_${version}_${architecture}.deb" \
        -print -quit
)

if [[ -z "$repo_deb" ]]; then
    echo "ERROR: repository lists $package $version but its .deb was not found" >&2
    exit 1
fi

candidate_sha=$(sha256sum "$deb_file" | awk '{print $1}')
repository_sha=$(sha256sum "$repo_deb" | awk '{print $1}')

if [[ "$candidate_sha" == "$repository_sha" ]]; then
    echo "SKIP: $package $version $architecture is already published"
    exit 0
fi

echo "ERROR: $package $version already exists with different contents" >&2
echo "       Bump the package version before publishing." >&2
exit 1
