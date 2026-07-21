#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

# Pinned known-good llama.cpp revision for reproducible local builds.
LLAMA_REF="${LLAMA_CPP_REF:-2405d59cb613f7b9f98ecbc9eb25f8a45188ee06}"
# Clone or update llama.cpp
LLAMA_DIR="/tmp/llama-cpp-build"
if [ -d "$LLAMA_DIR/.git" ]; then
    echo "==> Fetching llama.cpp..."
    git -C "$LLAMA_DIR" fetch --tags origin
else
    echo "==> Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
fi

echo "==> Checking out llama.cpp @ $LLAMA_REF..."
git -C "$LLAMA_DIR" checkout --force "$LLAMA_REF"

BUILD_DIR="$LLAMA_DIR/build-spm"

echo "==> Building llama.cpp with Metal + Accelerate (static libraries)..."

cmake -B "$BUILD_DIR" -S "$LLAMA_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_CURL=OFF

cmake --build "$BUILD_DIR" --config Release -j "$(sysctl -n hw.logicalcpu)"

echo "==> Copying static libraries..."
mkdir -p "$LIB_DIR"

# Copy llama library
cp "$BUILD_DIR/src/libllama.a" "$LIB_DIR/"
cp "$BUILD_DIR/common/libcommon.a" "$LIB_DIR/libllama-common.a"

# Replace shared ggml libraries (used by both whisper and llama)
# llama's ggml is a superset of whisper's — safe to use for both
cp "$BUILD_DIR/ggml/src/libggml.a" "$LIB_DIR/"
cp "$BUILD_DIR/ggml/src/libggml-base.a" "$LIB_DIR/"
cp "$BUILD_DIR/ggml/src/libggml-cpu.a" "$LIB_DIR/"
cp "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" "$LIB_DIR/"
cp "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a" "$LIB_DIR/"

# Copy updated ggml headers (newer than whisper's original headers)
HEADER_DIR="$PROJECT_ROOT/Sources/CWhisper/include"
cp "$LLAMA_DIR/ggml/include/ggml.h" "$HEADER_DIR/"
cp "$LLAMA_DIR/ggml/include/ggml-cpu.h" "$HEADER_DIR/"
cp "$LLAMA_DIR/ggml/include/ggml-backend.h" "$HEADER_DIR/"
cp "$LLAMA_DIR/ggml/include/ggml-alloc.h" "$HEADER_DIR/"
cp "$LLAMA_DIR/ggml/include/ggml-opt.h" "$HEADER_DIR/"
cp "$LLAMA_DIR/ggml/include/gguf.h" "$HEADER_DIR/"

# Copy llama header
cp "$LLAMA_DIR/include/llama.h" "$PROJECT_ROOT/Sources/CLlama/include/"

echo "==> Libraries copied to $LIB_DIR:"
ls -lh "$LIB_DIR"/lib*.a

echo "==> Done!"
