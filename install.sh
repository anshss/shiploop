#!/usr/bin/env bash
# LEGACY installer — clone-into-skills path. Symlinks commands/ into
# ~/.claude/commands/shiploop so slash commands work without a marketplace.
#
# NEW (preferred) install path is via the Claude Code plugin marketplace:
#   /plugin marketplace add anshss/shiploop
#   /plugin install shiploop@shiploop
#
# This installer stays supported for users who cloned the repo directly, and for
# CI / scripted environments that don't want to go through the plugin manager.
# Idempotent — safe to re-run after updates.
set -e

COMMANDS_DIR="$HOME/.claude/commands"
SOURCE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$COMMANDS_DIR/shiploop"

if [ ! -d "$COMMANDS_DIR" ]; then
  echo "Error: $COMMANDS_DIR not found. Is Claude Code installed?"
  exit 1
fi

if [ ! -d "$SOURCE/commands" ]; then
  echo "Error: $SOURCE/commands does not exist."
  exit 1
fi

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  echo "Removing existing $TARGET"
  rm -rf "$TARGET"
fi

ln -s "$SOURCE/commands" "$TARGET"

# Make templates executable in case git lost +x on clone (recurse — templates now
# has worktree/, govern/, hooks/, lib/ subdirs). Skip .example files.
if [ -d "$SOURCE/templates" ]; then
  find "$SOURCE/templates" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
fi

echo ""
echo "Installed: /shiploop:* commands now available in all Claude Code sessions."
echo "Source:    $SOURCE"
echo "Symlink:   $TARGET → $SOURCE/commands"
echo ""
echo "Available commands:"
for f in "$SOURCE/commands"/*.md; do
  [ -f "$f" ] && echo "  /shiploop:$(basename "$f" .md)"
done
echo ""
echo "Try: /shiploop:setup in a folder containing your sub-repos."
