#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WHISPER_DIR="$PROJECT_ROOT/whisper.cpp"
BUILD_DIR="$WHISPER_DIR/build-spm"
LIB_DIR="$PROJECT_ROOT/lib"

echo "==> Building whisper.cpp with Metal + Accelerate + CoreML..."

cmake -B "$BUILD_DIR" -S "$WHISPER_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON \
    -DWHISPER_COREML=ON \
    -DWHISPER_COREML_ALLOW_FALLBACK=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF

cmake --build "$BUILD_DIR" --config Release -j "$(sysctl -n hw.logicalcpu)"

echo "==> Copying static libraries..."
mkdir -p "$LIB_DIR"

# Copy whisper-specific static libraries. Shared ggml archives are owned by
# Scripts/build-llama.sh so whisper rebuilds do not silently mutate the app's
# transitive native link set.
cp "$BUILD_DIR/src/libwhisper.a" "$LIB_DIR/"

# Copy CoreML library if built
cp "$BUILD_DIR/src/libwhisper.coreml.a" "$LIB_DIR/" 2>/dev/null || true

# Also copy the Metal shader
METAL_SHADER="$BUILD_DIR/bin/ggml-metal.metal"
if [ -f "$METAL_SHADER" ]; then
    cp "$METAL_SHADER" "$LIB_DIR/"
fi
# Also check for .metallib
find "$BUILD_DIR" -name "*.metallib" -exec cp {} "$LIB_DIR/" \; 2>/dev/null || true

echo "==> Libraries copied to $LIB_DIR:"
ls -la "$LIB_DIR/"

echo "==> Done!"
