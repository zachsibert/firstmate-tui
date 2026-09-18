#!/usr/bin/env bash
# scripts/next-version.sh - the version the next release gets.
#
#   scripts/next-version.sh <package.json version> [existing tag...]
#
# Prints <version> when the tag v<version> is not among the tags given;
# otherwise increments the patch number until v<x.y.z> names no existing tag
# and prints that. The release workflow (.github/workflows/release.yml) calls
# it in both jobs with the repository's tags (git ls-remote --tags): the main
# job releases the printed version, committing the bump when it differs from
# package.json, and the beta job names its build <printed version>-<sha7>, so
# a beta carries the version that will be released. A bump to a higher patch,
# minor or major in package.json wins as long as its tag is free. Beta tags
# (v0.2.5-d8b290e) never equal an exact v<x.y.z> and are ignored. A version
# that is not X.Y.Z exits 2 with a message on stderr. Nothing is written.
set -euo pipefail

die() {
  printf 'next-version: %s\n' "$*" >&2
  exit 2
}

[ "$#" -ge 1 ] || die "usage: next-version.sh <version> [tag...]"
version=$1
shift
[[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "malformed version '$version': expected X.Y.Z"
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}

taken() { # <candidate>: is v<candidate> one of the tags?
  local tag
  for tag in "${@:2}"; do
    [ "$tag" = "v$1" ] && return 0
  done
  return 1
}

candidate=$version
while taken "$candidate" "$@"; do
  patch=$((patch + 1))
  candidate="$major.$minor.$patch"
done
printf '%s\n' "$candidate"
