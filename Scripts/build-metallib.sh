#!/usr/bin/env bash
# Build MLX Metal shader library (mlx.metallib) for SwiftPM builds.
# SwiftPM doesn't compile .metal sources, so we do it manually.
# Run once after `swift package resolve` or clean builds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

KERNELS_DIR="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels"
MLX_ROOT="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
OUT_DIR="$PROJECT_DIR/.build/debug"

if [ ! -d "$KERNELS_DIR" ]; then
    echo "MLX Swift not resolved yet. Run: swift package resolve"
    exit 1
fi

if [ -f "$OUT_DIR/mlx.metallib" ]; then
    echo "mlx.metallib already exists at $OUT_DIR/mlx.metallib"
    echo "Delete it to force rebuild."
    exit 0
fi

mkdir -p "$OUT_DIR"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo "Compiling MLX Metal shaders..."
ok=0
fail=0

find "$KERNELS_DIR" -name "*.metal" -print0 | while IFS= read -r -d '' metal_file; do
    base=$(basename "$metal_file" .metal)
    air_file="$TMP_DIR/${base}.air"
    if xcrun -sdk macosx metal -x metal -fno-fast-math \
        -Wno-c++17-extensions -Wno-c++20-extensions \
        -c "$metal_file" -I"$MLX_ROOT" -I"$KERNELS_DIR" \
        -o "$air_file" 2>/dev/null; then
        echo "  OK: $base"
    else
        echo "  SKIP: $base (needs newer Metal SDK)"
    fi
done

AIR_COUNT=$(find "$TMP_DIR" -name "*.air" | wc -l | tr -d ' ')
echo ""
echo "Compiled $AIR_COUNT Metal shaders"

if [ "$AIR_COUNT" -eq 0 ]; then
    echo "ERROR: No shaders compiled!"
    exit 1
fi

echo "Linking mlx.metallib..."
xcrun -sdk macosx metallib "$TMP_DIR"/*.air -o "$OUT_DIR/mlx.metallib"
echo "Done: $(ls -lh "$OUT_DIR/mlx.metallib" | awk '{print $5}') at $OUT_DIR/mlx.metallib"
