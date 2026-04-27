#!/bin/bash

echo
echo "--------------------------------------"
echo "        AOSP 16.0.0_r4 Buildbot       "
echo "                  by                  "
echo "                ponces                "
echo "--------------------------------------"
echo

set -e

export BUILD_NUMBER="$(date +%y%m%d)"

[ -z "$OUTPUT_DIR" ] && OUTPUT_DIR="$PWD/output"
[ -z "$BUILD_ROOT" ] && BUILD_ROOT="$PWD/treble_aosp"
[ -z "$SRC_DIR" ] && SRC_DIR="$PWD/aosp-src"
[ -z "$JOBS" ] && JOBS=$(nproc --all)

while getopts "j:s:" opt; do
    case $opt in
        j) JOBS="$OPTARG" ;;
        s) SRC_DIR="$OPTARG" ;;
        \?) echo "Usage: $0 [-j JOBS] [-s SRC_DIR] [VARIANT]" && exit 1 ;;
    esac
done
shift $((OPTIND-1))
[ -z "$BUILD_VARIANT" ] && [ ! -z "$1" ] && BUILD_VARIANT="$1"

initRepos() {
    echo "--> Initializing workspace"
    
    # Check if Google authentication is configured
    if [ -f ~/.gitcookies ] || git config --global credential.helper | grep -q .; then
        echo "--> Using authenticated access for higher rate limits"
        repo init -u https://android.googlesource.com/platform/manifest -b android-16.0.0_r4 --git-lfs
    else
        echo "--> No Google authentication found. Using anonymous access."
        echo "--> Tip: Visit https://android.googlesource.com/new-password to set up authentication for higher rate limits"
        repo init -u https://android.googlesource.com/platform/manifest -b android-16.0.0_r4 --git-lfs
    fi
    echo

    echo "--> Preparing local manifest"
    mkdir -p .repo/local_manifests
    cp $BUILD_ROOT/build/default.xml .repo/local_manifests/default.xml
    cp $BUILD_ROOT/build/remove.xml .repo/local_manifests/remove.xml
    echo
}

resetRepos() {
    echo "--> Resetting all repositories to clean state"
    repo forall -c '
        git am --abort 2>/dev/null || true
        git rebase --abort 2>/dev/null || true
        git reset --hard HEAD 2>/dev/null || true
        git clean -fdx 2>/dev/null || true
    ' || true
    echo
}

syncRepos() {
    echo "--> Syncing repos with $JOBS parallel jobs"
    repo sync -c --force-sync --no-clone-bundle --no-tags -j$JOBS || {
        echo "--> First sync failed, retrying..."
        repo sync -c --force-sync --no-clone-bundle --no-tags -j$JOBS || {
            echo "--> ERROR: repo sync failed completely!"
            exit 1
        }
    }
    echo
}

applyPatches() {
    echo "--> Applying TrebleDroid patches"
    echo "    Source: patches/trebledroid/"
    bash $BUILD_ROOT/patch.sh $BUILD_ROOT trebledroid
    echo

    echo "--> Applying personal patches"
    echo "    Source: patches/personal/"
    bash $BUILD_ROOT/patch.sh $BUILD_ROOT personal
    echo

    echo "--> Applying staging patches"
    echo "    Source: patches/staging/"
    bash $BUILD_ROOT/patch.sh $BUILD_ROOT staging
    echo

    echo "--> Generating makefiles"
    cd device/phh/treble
    cp $BUILD_ROOT/build/aosp.mk .
    bash generate.sh aosp
    cd ../../..
    echo
}

setupEnv() {
    echo "--> Setting up build environment"
    mkdir -p $OUTPUT_DIR
    source build/envsetup.sh
    source build/core/build_id.mk
    echo
}

buildTrebleApp() {
    echo "--> Building treble_app"
    cd treble_app
    bash build.sh release
    cp TrebleApp.apk ../vendor/hardware_overlay/TrebleApp/app.apk
    cd ..
    echo
}

buildVariant() {
    echo "--> Building $1"
    lunch "$1"-bp4a-userdebug
    make -j$JOBS installclean
    make -j$JOBS systemimage
    make -j$JOBS target-files-package otatools
    bash $BUILD_ROOT/sign.sh "vendor/ponces-priv/keys" $OUT/signed-target_files.zip
    unzip -joq $OUT/signed-target_files.zip IMAGES/system.img -d $OUT
    mv $OUT/system.img $OUTPUT_DIR/system-"$1".img
    echo
}

buildVariants() {
    buildVariant treble_arm64_bvN
    buildVariant treble_arm64_bgN
}

generatePackages() {
    echo "--> Generating packages"
    buildDate="$(date +%Y%m%d)"
    find $OUTPUT_DIR/ -name "system-treble_*.img" | while read file; do
        filename="$(basename $file)"
        [[ "$filename" == *"_bvN"* ]] && variant="vanilla" || variant="gapps"
        name="aosp-arm64-ab-${variant}-16.0-$buildDate"
        xz -cv "$file" -T0 > $OUTPUT_DIR/"$name".img.xz
    done
    rm -rf $OUTPUT_DIR/system-*.img
    echo
}

generateOta() {
    echo "--> Generating OTA file"
    version="$(date +v%Y.%m.%d)"
    buildDate="$(date +%Y%m%d)"
    timestamp="$START"
    json="{\"version\": \"$version\",\"date\": \"$timestamp\",\"variants\": ["
    find $OUTPUT_DIR/ -name "aosp-*-16.0-$buildDate.img.xz" | sort | {
        while read file; do
            filename="$(basename $file)"
            [[ "$filename" == *"-vanilla"* ]] && variant="v" || variant="g"
            name="treble_arm64_b${variant}N"
            size=$(wc -c $file | awk '{print $1}')
            url="https://github.com/ponces/treble_aosp/releases/download/$version/$filename"
            json="${json} {\"name\": \"$name\",\"size\": \"$size\",\"url\": \"$url\"},"
        done
        json="${json%?}]}"
        echo "$json" | jq . > $BUILD_ROOT/config/ota.json
    }
    echo
}

START=$(date +%s)

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"
SRC_DIR="$PWD"

initRepos
resetRepos
syncRepos
applyPatches
setupEnv
buildTrebleApp
[ ! -z "$BUILD_VARIANT" ] && buildVariant "$BUILD_VARIANT" || buildVariants
generatePackages
# generateOta

END=$(date +%s)
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))

echo "--> Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo
