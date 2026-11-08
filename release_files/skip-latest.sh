#!/usr/bin/env bash
# Decide whether a release tag should move the "latest" pointers: the Docker
# `latest` tags, the Homebrew formula, GitHub's "Latest release" (set by the
# signing pipeline, which also updates the cask and Chocolatey) and the
# FreeBSD port.
#
# Prints the value for SKIP_LATEST: "true" means leave them alone, "false"
# means this tag is the newest release line and may move them. The name
# matches the variable so nothing has to invert the answer at the call site.
#
# Usage: release_files/skip-latest.sh v0.81.0
#
# Candidate tags come from `git tag -l 'v*'` in the current repository, so the
# checkout needs the tags. Set SKIP_LATEST_TAGS to a newline-separated list to
# supply them directly -- which is what the tests do:
#
#   SKIP_LATEST_TAGS='v0.80.3
#   v0.81.0' release_files/skip-latest.sh v0.80.3
#
# It is the variable being *set* that switches the source, not it being
# non-empty, so an empty value is an empty list rather than "ask git".
#
# The tag itself must be in the list. If it isn't, the list is broken -- a
# checkout without tags, an empty ls-remote -- and the script exits 1 rather
# than guess, since every guess about an empty list would move latest.
#
# Rules, in order:
#
#   1. Numbered -custom.N releases compare only with other numbered fork releases.
#   2. Other prerelease tags never move latest.
#   3. Otherwise it moves latest only if its version is >= the newest release
#      already tagged, so a patch on an older line cannot drag it backwards.
#
# Prereleases are excluded from "newest release" deliberately. `sort -V`
# orders 0.81.0-rc.1 *after* 0.81.0 -- unlike semver it treats `-` as an
# ordinary separator, and only `~` sorts lower. Leaving release candidates in
# the comparison would make a release look older than its own RC, and latest
# would never move.
set -euo pipefail

# Additional release policy operations share the same source and latest rules.
# Usage: skip-latest.sh <check-draft|prepare|seal|verify|publish> <tag> [--assets DIR]
case "${1:-}" in
  check-draft|prepare|seal|verify|publish)
    python3 - "$0" "$@" <<'RELEASE_POLICY_PY'
#!/usr/bin/env python3
"""Prepare, seal and promote NetBird fork releases without rebuilding artifacts."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPOSITORY = "qiudesong/netbird"
NUMBER = r"(?:0|[1-9][0-9]*)"
TAG = re.compile(rf"v({NUMBER})\.({NUMBER})\.({NUMBER})-custom\.([1-9][0-9]*)")
POLICY_SCRIPT = Path(sys.argv[1]).resolve()


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def version_key(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError(f"expected vX.Y.Z-custom.N with N >= 1: {tag}")
    return tuple(map(int, match.groups()))


def image_targets(tag):
    """Read versioned images and promotion aliases from the shared build config."""
    version_key(tag)
    config = json.loads(run("ruby", "-rjson", "-ryaml", "-e",
        "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))", ".goreleaser.yaml"))
    targets = {}
    for image in config["dockers_v2"]:
        versions, aliases = [], []
        for value in image["tags"]:
            alias = re.fullmatch(r'{{\s*if eq \.Env\.SKIP_LATEST "false"\s*}}([^{}]+){{\s*end\s*}}', value)
            if alias:
                aliases.append(alias[1])
            else:
                rendered = re.sub(r"{{\s*\.Version\s*}}", tag[1:], value)
                if "{{" in rendered:
                    raise ValueError(f"unsupported image tag template: {value}")
                versions.append(rendered)
        if len(versions) != 1 or len(aliases) != 1 or not aliases[0].startswith("custom-"):
            raise ValueError(f"review changed image promotion rules: {image['id']}")
        for name in image["images"]:
            if not name.startswith("ghcr.io/qiudesong/"):
                raise ValueError(f"unexpected image registry: {name}")
            targets[f"{name}:{versions[0]}"] = f"{name}:{aliases[0]}"
    return targets


def check_draft(tag):
    version_key(tag)
    result = subprocess.run(
        ["gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}"],
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        if "(HTTP 404)" in result.stderr:
            return
        raise ValueError(result.stderr.strip())
    if not json.loads(result.stdout)["draft"]:
        raise ValueError("published releases cannot be rebuilt or overwritten")


def prepare(tag, output):
    major, minor, patch, revision = version_key(tag)
    if any(value > 65535 for value in (major, minor, patch, revision)):
        raise ValueError("version exceeds the Windows four-part version limit")
    base = f"v{major}.{minor}.{patch}"
    if run("git", "cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise ValueError("release tag must be annotated or signed")
    commit = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}")
    if commit != run("git", "rev-parse", "HEAD"):
        raise ValueError("checkout does not match the release tag")
    upstream = run("git", "rev-parse", f"refs/upstream-tags/{base}^{{commit}}")
    subprocess.run(["git", "merge-base", "--is-ancestor", upstream, commit], check=True)
    allowed = ("origin/main", f"origin/release-{major}.{minor}")
    branches = run("git", "for-each-ref", f"--contains={commit}",
                   "--format=%(refname:short)", "refs/remotes/origin/").splitlines()
    if not set(allowed).intersection(branches):
        raise ValueError(f"release commit must belong to {' or '.join(allowed)}")
    output.mkdir(parents=True, exist_ok=True)
    metadata = dict(tag=tag, commit=commit, upstream_tag=base,
                    upstream_commit=upstream, custom_revision=revision)
    (output / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    # The existing version fetcher expects the version text without a newline.
    (output / "version").write_text(tag[1:])
    previous = []
    for item in run("git", "tag", "--merged", commit, "--list", "v*-custom.*").splitlines():
        if TAG.fullmatch(item) and version_key(item) < version_key(tag):
            previous.append(item)
    start = max(previous, key=version_key) if previous else upstream
    changes = run("git", "log", "--no-merges", "--format=- %s (%h)", f"{start}..{commit}")
    notes = (f"Based on upstream `{base}` (`{upstream}`).\n\n"
             f"Fork commit: `{commit}`.\n\n{changes or 'No downstream code changes.'}\n")
    (output / "release-notes.md").write_text(notes)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def seal(tag, output):
    images = {image: dict(latest=latest, digest=run("docker", "buildx", "imagetools", "inspect", "--format",
                        "{{.Manifest.Digest}}", image))
              for image, latest in sorted(image_targets(tag).items())}
    if not all(re.fullmatch(r"sha256:[0-9a-f]{64}", value["digest"]) for value in images.values()):
        raise ValueError("invalid image manifest digest")
    assets = output / "assets"
    subprocess.run(["gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", str(assets)], check=True)
    (assets / "images.json").write_text(json.dumps(dict(tag=tag, images=images), indent=2) + "\n")
    files = [path for path in assets.iterdir() if path.name not in ("SHA256SUMS", "SHA256SUMS.asc")]
    if not files:
        raise ValueError("no release assets found")
    if any(not path.is_file() or path.is_symlink() or not re.fullmatch(r"[A-Za-z0-9_.+~-]+", path.name) for path in files):
        raise ValueError("invalid release asset filename")
    sums = "".join(f"{digest(path)}  {path.name}\n" for path in sorted(files))
    (assets / "SHA256SUMS").write_text(sums)


def verify(tag, assets):
    version_key(tag)
    expected = {}
    for line in (assets / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.+~-]+)", line)
        if not match or match[2] in expected:
            raise ValueError("invalid checksum manifest or duplicate filename")
        expected[match[2]] = match[1]
    actual = {path.name for path in assets.iterdir()
              if path.name not in ("SHA256SUMS", "SHA256SUMS.asc")}
    required = {"version", "release.json", "images.json", "signing-key.asc", "install.sh"}
    if actual != set(expected) or not required.issubset(actual):
        raise ValueError("release assets do not match the signed manifest")
    for name, value in expected.items():
        path = assets / name
        if path.is_symlink() or not path.is_file() or digest(path) != value:
            raise ValueError(f"checksum mismatch: {name}")
    if (assets / "version").read_text() != tag[1:]:
        raise ValueError("update version does not match the release tag")
    metadata = json.loads((assets / "release.json").read_text())
    if metadata["tag"] != tag or metadata["commit"] != run("git", "rev-parse", "HEAD"):
        raise ValueError("release provenance does not match the checked-out tag")
    manifest = json.loads((assets / "images.json").read_text())
    targets = image_targets(tag)
    if manifest["tag"] != tag or set(manifest["images"]) != set(targets):
        raise ValueError("image manifest does not match the fork release")
    if not all(value["latest"] == targets[image] and re.fullmatch(r"sha256:[0-9a-f]{64}", value["digest"])
               for image, value in manifest["images"].items()):
        raise ValueError("invalid image digest")
    return manifest["images"]


def publish(tag, assets):
    images = verify(tag, assets)
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases"))
    tags = [item["tag_name"] for page in pages for item in page
            if not item["draft"] and not item["prerelease"] and TAG.fullmatch(item["tag_name"])]
    environment = dict(os.environ, SKIP_LATEST_TAGS="\n".join(tags + [tag]))
    latest = subprocess.check_output(["bash", str(POLICY_SCRIPT), tag], env=environment, text=True).strip() == "false"
    if latest:
        for image, value in sorted(images.items()):
            subprocess.run(["docker", "buildx", "imagetools", "create", "--tag",
                            value["latest"], f"{image.split(':')[0]}@{value['digest']}"], check=True)
    subprocess.run(["gh", "release", "edit", tag, "--repo", REPOSITORY,
                    "--draft=false", "--prerelease=false", f"--latest={str(latest).lower()}"], check=True)
    print(f"Published {tag}; moved custom-latest: {latest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check-draft", "prepare", "seal", "verify", "publish"))
    parser.add_argument("tag")
    parser.add_argument("--assets", type=Path, default=Path(".release"))
    args = parser.parse_args(sys.argv[2:])
    if args.command == "check-draft":
        check_draft(args.tag)
    elif args.command == "prepare":
        prepare(args.tag, args.assets)
    elif args.command == "seal":
        seal(args.tag, args.assets)
    elif args.command == "verify":
        verify(args.tag, args.assets)
    else:
        publish(args.tag, args.assets)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
RELEASE_POLICY_PY
    exit $?
    ;;
esac

tag=${1:-}
if [[ -z "$tag" ]]; then
  echo "usage: $0 <tag>" >&2
  exit 2
fi

version=${tag#v}

if [[ -n "${SKIP_LATEST_TAGS+set}" ]]; then
  candidates=$SKIP_LATEST_TAGS
else
  candidates=$(git tag -l 'v*')
fi

# A here-string, not printf piped into grep -q: grep exits at the first match,
# and under pipefail the SIGPIPE that leaves printf with would read as a miss.
if ! grep -Fxq -- "$tag" <<<"$candidates"; then
  echo "$0: $tag is not in the tag list -- refusing to decide on a broken list" >&2
  exit 1
fi

# A numbered downstream revision is a stable release in its own channel.
# Filter out official tags, drafts supplied by the caller, and other suffixes.
number='(0|[1-9][0-9]*)'
custom_pattern="^v${number}\.${number}\.${number}-custom\.[1-9][0-9]*$"
if [[ "$tag" =~ $custom_pattern ]]; then
  newest=$(printf '%s\n' "$candidates" | sed -nE "/${custom_pattern}/p" | sort -uV | tail -1)
  if [[ "$newest" == "$tag" ]]; then
    echo ":: $tag is the newest fork release -- it moves custom-latest" >&2
    printf 'false\n'
  else
    echo ":: $tag is older than $newest -- custom-latest stays where it is" >&2
    printf 'true\n'
  fi
  exit 0
fi

# Strip the v prefix, drop anything holding a hyphen (prereleases, canaries,
# the odd -hotfix-N), and take the highest. `sed` rather than `grep -v` so an
# empty result is not a pipeline failure.
newest=$(printf '%s\n' "$candidates" \
  | sed -E 's/^v//; /-/d; /^$/d' \
  | sort -uV \
  | tail -1)

skip=true
if [[ "${version#*-}" != "$version" ]]; then
  echo ":: $version is a prerelease -- latest never moves" >&2
elif [[ "$(printf '%s\n%s\n' "$version" "$newest" | sort -V | tail -1)" = "$version" ]]; then
  skip=false
  echo ":: $version is the newest release -- it moves latest" >&2
else
  echo ":: $version is older than $newest -- latest stays where it is" >&2
fi

printf '%s\n' "$skip"
