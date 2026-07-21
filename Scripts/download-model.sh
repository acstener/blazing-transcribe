#!/bin/bash
set -euo pipefail

MODEL_NAME="${1:-ggml-base.en.bin}"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
DEST_DIR="$HOME/Library/Application Support/BlazingFastTranscription/Models"

mkdir -p "$DEST_DIR"

DEST_FILE="$DEST_DIR/$MODEL_NAME"

if [ -f "$DEST_FILE" ]; then
    echo "Model already exists: $DEST_FILE"
    exit 0
fi

echo "Downloading $MODEL_NAME..."
curl -L --progress-bar \
    "$BASE_URL/$MODEL_NAME" \
    -o "$DEST_FILE"

echo "Downloaded to: $DEST_FILE"
echo "Size: $(du -h "$DEST_FILE" | cut -f1)"
