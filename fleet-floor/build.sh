#!/usr/bin/env sh
# Assemble a self-contained, dependency-free index.html from src/.
# No build tools, no network, no external assets — just concatenation.
set -eu
cd "$(dirname "$0")"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  printf '<title>Fleet Floor</title>\n'
  printf '<style>\n'
  cat src/style.css
  printf '\n</style>\n</head>\n<body>\n'
  cat src/body.html
  printf '<script>\n'
  cat src/app.js
  printf '\n</script>\n</body>\n</html>\n'
} > index.html
echo "built index.html ($(wc -c < index.html) bytes)"
