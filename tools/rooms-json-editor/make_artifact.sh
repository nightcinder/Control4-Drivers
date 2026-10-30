#!/bin/sh
# The Claude artifact page is index.html without its first four lines (doctype, <html>, charset, viewport).
# Writes artifact.html next to this script. Publishing that file as the artifact keeps the two identical.
cd "$(dirname "$0")" && tail -n +5 index.html > artifact.html && echo "wrote artifact.html"
