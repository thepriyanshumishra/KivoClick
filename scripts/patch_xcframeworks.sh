#!/bin/bash

# Find DerivedData directory
DERIVED_DATA_DIRS=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "leanring-buddy-*")

if [ -z "$DERIVED_DATA_DIRS" ]; then
    echo "Could not find leanring-buddy DerivedData directory."
    exit 1
fi

for DD in $DERIVED_DATA_DIRS; do
    echo "Processing DerivedData at: $DD"
    
    ARTIFACTS_DIR="$DD/SourcePackages/artifacts/sherpa-onnx-spm"
    if [ ! -d "$ARTIFACTS_DIR" ]; then
        echo "Artifacts directory not found in this DerivedData folder."
        continue
    fi
    
    # 1. First, restore everything to clean state if previously modified
    ONNX_XCFRAMEWORK="$ARTIFACTS_DIR/onnxruntime/onnxruntime.xcframework"
    if [ -d "$ONNX_XCFRAMEWORK" ]; then
        for PLATFORM_DIR in "$ONNX_XCFRAMEWORK"/*; do
            if [ -d "$PLATFORM_DIR/Headers/onnxruntime" ]; then
                echo "Restoring onnxruntime headers in $PLATFORM_DIR"
                mv "$PLATFORM_DIR/Headers/onnxruntime"/*.h "$PLATFORM_DIR/Headers/" 2>/dev/null
                mv "$PLATFORM_DIR/Headers/onnxruntime/module.modulemap" "$PLATFORM_DIR/Headers/" 2>/dev/null
                rmdir "$PLATFORM_DIR/Headers/onnxruntime"
            fi
        done
    fi
    
    SHERPA_XCFRAMEWORK="$ARTIFACTS_DIR/sherpa-onnx/sherpa-onnx.xcframework"
    if [ -d "$SHERPA_XCFRAMEWORK" ]; then
        for PLATFORM_DIR in "$SHERPA_XCFRAMEWORK"/*; do
            if [ -d "$PLATFORM_DIR/Headers/sherpa_onnx" ]; then
                echo "Restoring sherpa-onnx headers in $PLATFORM_DIR"
                mv "$PLATFORM_DIR/Headers/sherpa_onnx"/sherpa-onnx "$PLATFORM_DIR/Headers/" 2>/dev/null
                mv "$PLATFORM_DIR/Headers/sherpa_onnx"/*.h "$PLATFORM_DIR/Headers/" 2>/dev/null
                mv "$PLATFORM_DIR/Headers/sherpa_onnx/module.modulemap" "$PLATFORM_DIR/Headers/" 2>/dev/null
                rmdir "$PLATFORM_DIR/Headers/sherpa_onnx"
            fi
        done
    fi
    
    # 2. Now, apply the clean fix: delete module.modulemap ONLY from onnxruntime.xcframework
    if [ -d "$ONNX_XCFRAMEWORK" ]; then
        echo "Applying fix: Removing module.modulemap from onnxruntime.xcframework..."
        for PLATFORM_DIR in "$ONNX_XCFRAMEWORK"/*; do
            if [ -f "$PLATFORM_DIR/Headers/module.modulemap" ]; then
                rm "$PLATFORM_DIR/Headers/module.modulemap"
                echo "Deleted module.modulemap from $PLATFORM_DIR/Headers/"
            fi
        done
    fi
done

# Run Swift API patcher
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/patch_sherpa_onnx_swift.py"

echo "Patch complete!"
