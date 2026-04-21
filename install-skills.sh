#!/usr/bin/env bash
# Install the Claude Code skills shipped by this repo into ~/.claude/skills/
# by symlinking each subdirectory of ./skills/ into place. Idempotent; safe
# to run repeatedly. Pass --force to overwrite files or symlinks that don't
# already point at our source.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$REPO_ROOT/skills"
TARGET_DIR="$HOME/.claude/skills"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "No skills/ directory at $SOURCE_DIR — nothing to install."
  exit 0
fi

mkdir -p "$TARGET_DIR"

for source_skill in "$SOURCE_DIR"/*/; do
  [[ -d "$source_skill" ]] || continue
  source_skill="${source_skill%/}"
  name=$(basename "$source_skill")
  target="$TARGET_DIR/$name"

  if [[ -L "$target" ]]; then
    actual=$(readlink "$target")
    if [[ "$actual" == "$source_skill" ]]; then
      echo "✓ $name (already linked)"
      continue
    fi
    if [[ $FORCE -eq 1 ]]; then
      rm "$target"
    else
      echo "⚠ $name: existing symlink points to $actual — pass --force to replace."
      continue
    fi
  elif [[ -e "$target" ]]; then
    if [[ $FORCE -eq 1 ]]; then
      rm -rf "$target"
    else
      echo "⚠ $name: $target exists and isn't a symlink — pass --force to replace."
      continue
    fi
  fi

  ln -s "$source_skill" "$target"
  echo "✓ $name → $source_skill"
done
