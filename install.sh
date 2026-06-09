#!/usr/bin/env bash
# Install the /meta-repo:* slash commands by symlinking commands/ into
# ~/.claude/commands/meta-repo. Idempotent — safe to re-run after updates.
set -e

COMMANDS_DIR="$HOME/.claude/commands"
SOURCE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$COMMANDS_DIR/meta-repo"

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
echo "Installed: /meta-repo:* commands now available in all Claude Code sessions."
echo "Source:    $SOURCE"
echo "Symlink:   $TARGET → $SOURCE/commands"
echo ""
echo "Available commands:"
for f in "$SOURCE/commands"/*.md; do
  [ -f "$f" ] && echo "  /meta-repo:$(basename "$f" .md)"
done
echo ""
echo "Try: /meta-repo:setup in a folder containing your sub-repos."
