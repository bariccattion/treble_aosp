#!/bin/bash

set -e

patches="$(readlink -f -- $1)"
tree="$2"

apply_patches() {
    local project=$1
    local project_path
    
    project_path="$(tr _ / <<<$project |sed -e 's;platform/;;g')"
    [ "$project_path" == build ] && project_path=build/make
    [ "$project_path" == treble/app ] && project_path=treble_app
    [ "$project_path" == vendor/hardware/overlay ] && project_path=vendor/hardware_overlay
    
    echo "    --> Patching: $project_path"
    
    if [ ! -d "$project_path" ]; then
        echo "    --> ERROR: Directory $project_path does not exist"
        echo "    --> Skipping $project"
        return 0
    fi
    
    pushd "$project_path" 1>/dev/null
    
    # Reset repository to clean state before applying patches
    git am --abort 2>/dev/null || true
    git reset --hard HEAD 2>/dev/null
    git clean -fd 2>/dev/null
    
    local patch_count=0
    local failed_patch=""
    
    for patch in $patches/patches/$tree/$project/*.patch; do
        [ -e "$patch" ] || continue
        patch_count=$((patch_count + 1))
        
        local patch_name
        patch_name=$(basename "$patch")
        echo "        Applying: $patch_name"
        
        if ! git am "$patch" 2>&1; then
            failed_patch="$patch_name"
            echo ""
            echo "    ============================================"
            echo "    PATCH FAILED"
            echo "    ============================================"
            echo "    Patch source:    patches/$tree/$project"
            echo "    Target project:  $project_path"
            echo "    Failed patch:    $patch_name"
            echo "    ============================================"
            echo ""
            echo "    Git am error details:"
            echo "    ----------------------------------------"
            git am --show-current-patch=diff 2>/dev/null | head -50
            echo "    ----------------------------------------"
            echo ""
            echo "    To resolve:"
            echo "      1. cd $project_path"
            echo "      2. git am --abort    # to cancel"
            echo "      3. git am --skip     # to skip this patch"
            echo "      Or manually resolve and: git am --continue"
            echo ""
            popd 1>/dev/null
            return 1
        fi
    done
    
    popd 1>/dev/null
    echo "    --> Applied $patch_count patches to $project_path"
}

for project in $(cd $patches/patches/$tree; echo *); do
    apply_patches "$project" || exit 1
done
