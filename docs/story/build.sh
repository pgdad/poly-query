#!/usr/bin/env bash
# Rebuilds the story charts, story.html and story.pdf (pandoc + headless Chrome).
set -euo pipefail
cd "$(dirname "$0")"
python3 ../../tools/reporting/story_assets.py
pandoc README.md -f gfm -t html5 -s --metadata title="One Weekend, Eight Databases" --css story.css -o story.html
pandoc vsnc.md -f gfm -t html5 -s --metadata title="PolyQuery: One spec. Eight languages. One answer." --css story.css -o vsnc.html
sed -i '/<header id="title-block-header">/,/<\/header>/d' story.html vsnc.html
profile=$(mktemp -d)
trap 'rm -rf "${profile:?}"' EXIT
google-chrome --headless=new --disable-gpu --no-first-run --user-data-dir="$profile" --no-pdf-header-footer \
  --print-to-pdf=story.pdf story.html 2>/dev/null
google-chrome --headless=new --disable-gpu --no-first-run --user-data-dir="$profile" --no-pdf-header-footer \
  --print-to-pdf=vsnc.pdf vsnc.html 2>/dev/null
echo "wrote story.html, story.pdf, vsnc.html, vsnc.pdf"
