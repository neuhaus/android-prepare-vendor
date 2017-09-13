#!/usr/bin/env bash
#
#  Generate AOSP compatible vendor data for provided device & buildID
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_prepare_vendor.XXXXXX) || exit 1
declare -a SYS_TOOLS=("mkdir" "dirname" "wget" "mount")

# Realpath implementation in bash
readonly REALPATH_SCRIPT="$SCRIPTS_ROOT/scripts/realpath.sh"

# Script that contain global constants
readonly CONSTS_SCRIPT="$SCRIPTS_ROOT/scripts/constants.sh"

# Helper script to download Nexus factory images from web
readonly DOWNLOAD_SCRIPT="$SCRIPTS_ROOT/scripts/download-nexus-image.sh"

# Helper script to extract system & vendor images data
readonly EXTRACT_SCRIPT="$SCRIPTS_ROOT/scripts/extract-factory-images.sh"

# Helper script to generate "proprietary-blobs.txt" file
readonly GEN_BLOBS_LIST_SCRIPT="$SCRIPTS_ROOT/scripts/gen-prop-blobs-list.sh"

# Helper script to repair bytecode prebuilt archives
readonly REPAIR_SCRIPT="$SCRIPTS_ROOT/scripts/system-img-repair.sh"

# Helper script to generate vendor AOSP includes & makefiles
readonly VGEN_SCRIPT="$SCRIPTS_ROOT/scripts/generate-vendor.sh"

abort() {
  # Remove mount points in case of error
  if [[ $1 -ne 0 && "$FACTORY_IMGS_DATA" != "" ]]; then
    unmount_raw_image "$FACTORY_IMGS_DATA/system"
    unmount_raw_image "$FACTORY_IMGS_DATA/vendor"
  fi
  rm -rf "$TMP_WORK_DIR"
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -d|--device  : Device codename (angler, bullhead, etc.)
      -a|--alias   : Device alias (e.g. flounder volantis (WiFi) vs volantisg (LTE))
      -b|--buildID : BuildID string (e.g. MMB29P)
      -o|--output  : Path to save generated vendor data
      -f|--full    : Use blobs configuration with all non-essential OEM packages + compatible with GApps
      -i|--img     : [OPTIONAL] Read factory image archive from file instead of downloading
      -k|--keep    : [OPTIONAL] Keep all factory images extracted & repaired data
      -s|--skip    : [OPTIONAL] Skip /system bytecode repairing (for debug purposes)
      -j|--java    : [OPTIONAL] Java path to use instead of system auto detected global version
      -y|--yes     : [OPTIONAL] Auto accept Google ToS when downloading Nexus factory images
      --force-opt  : [OPTIONAL] Disable LOCAL_DEX_PREOPT overrides for /system bytecode
      --oatdump    : [OPTIONAL] Force use of oatdump method to revert preoptimized bytecode
      --smali      : [OPTIONAL] Force use of smali/baksmali to revert preoptimized bytecode
      --smaliex    : [OPTIONAL] Force use of smaliEx to revert preoptimized bytecode [DEPRECATED]
      --deodex-all : [OPTIONAL] De-optimize all packages under /system
      --debugfs    : [OPTIONAL] Use debugfs instead of default fuse-ext2, to extract image files data
      --force-vimg : [OPTIONAL] Force factory extracted blobs under /vendor to be always used regardless AOSP definitions

    INFO:
      * Default configuration is naked. Use "-f|--full" if you plan to install Google Play Services
        or you have issues with some carriers
      * Default bytecode de-optimization repair choise is based on most stable/heavily-tested method
        If you need something on the top of defaults, you can select manually.
      * Until fuse-ext2 problems are resolved for Linux workstations, "--debugfs" is used by default
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

check_bash_version() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "[-] Minimum supported version of bash is 4.x"
    abort 1
  fi
}

unmount_raw_image() {
  local mount_point="$1"

  if [[ -d "$mount_point" && "$USE_DEBUGFS" = false ]]; then
    $_UMOUNT "$mount_point" || {
      echo "[-] '$mount_point' unmount failed"
      exit 1
    }
  fi
}

oatdump_prepare_env() {
  local api_level="$1"

  local download_url
  local out_file="$SCRIPTS_ROOT/hostTools/$HOST_OS/api-$api_level/oatdump_deps.zip"
  mkdir -p "$(dirname "$out_file")"


  if [[ "$HOST_OS" == "Darwin" ]]; then
    download_url="D_OATDUMP_URL_API$api_level"
  else
    download_url="L_OATDUMP_URL_API$api_level"
  fi

  wget -O "$out_file" "${!download_url}" || {
    echo "[-] oatdump dependencies download failed"
    abort 1
  }

  unzip -qq "$out_file" -d "$SCRIPTS_ROOT/hostTools/$HOST_OS/api-$api_level" || {
    echo "[-] oatdump dependencies unzip failed"
    abort 1
  }
}

is_aosp_root() {
  local targetDir="$1"
  if [ -f "$targetDir/.repo/project.list" ]; then
    return 0
  fi
  return 1
}

is_pixel() {
  local device="$1"
  if [[ "$device" == "marlin" || "$device" == "sailfish" ]]; then
    return 0
  fi
  return 1
}

trap "abort 1" SIGINT SIGTERM
. "$REALPATH_SCRIPT"
. "$CONSTS_SCRIPT"

# Global variables
DEVICE=""
BUILDID=""
OUTPUT_DIR=""
INPUT_IMG=""
KEEP_DATA=false
HOST_OS=""
DEV_ALIAS=""
API_LEVEL=""
SKIP_SYSDEOPT=false
_UMOUNT=""
FACTORY_IMGS_DATA=""
CONFIG="config-naked"
USER_JAVA_PATH=""
AUTO_TOS_ACCEPT=true
FORCE_PREOPT=false
FORCE_SMALI=false
FORCE_OATDUMP=false
FORCE_SMALIEX=false
BYTECODE_REPAIR_METHOD=""
DEODEX_ALL=false
AOSP_ROOT=""
USE_DEBUGFS=false
FORCE_VIMG=false

# Compatibility
check_bash_version
HOST_OS=$(uname)
if [[ "$HOST_OS" != "Linux" && "$HOST_OS" != "Darwin" ]]; then
  echo "[-] '$HOST_OS' OS is not supported"
  abort 1
fi

# Platform specific commands
if [[ "$HOST_OS" == "Darwin" ]]; then
  SYS_TOOLS+=("umount")
  _UMOUNT=umount
else
  SYS_TOOLS+=("fusermount")
  _UMOUNT="fusermount -u"

  # Until fuse-ext2 problems are resolved for Linux, use debugfs by default
  USE_DEBUGFS=true
fi

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

while [[ $# -gt 0 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR="$(_realpath "$2")"
      shift
      ;;
    -d|--device)
      DEVICE=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -a|--alias)
      DEV_ALIAS=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -b|--buildID)
      BUILDID=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -i|--imgs)
      INPUT_IMG="$(_realpath "$2")"
      shift
      ;;
    -f|--full)
      CONFIG="config-full"
      ;;
    -k|--keep)
      KEEP_DATA=true
      ;;
    -s|--skip)
      SKIP_SYSDEOPT=true
      ;;
    -j|--java)
      USER_JAVA_PATH="$(_realpath "$2")"
      shift
      ;;
    -y|--yes)
      AUTO_TOS_ACCEPT=true
      ;;
    --force-opt)
      FORCE_PREOPT=true
      ;;
    --smali)
      FORCE_SMALI=true
      ;;
    --smaliex)
      FORCE_SMALIEX=true
      ;;
    --oatdump)
      FORCE_OATDUMP=true
      ;;
    --deodex-all)
      DEODEX_ALL=true
      ;;
    --debugfs)
      USE_DEBUGFS=true
      ;;
    --force-vimg)
      FORCE_VIMG=true
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

# Check user input args
if [[ "$DEVICE" == "" ]]; then
  echo "[-] device codename cannot be empty"
  usage
fi
if [[ "$BUILDID" == "" ]]; then
  echo "[-] buildID cannot be empty"
  usage
fi
if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi
if [[ "$INPUT_IMG" != "" && ! -f "$INPUT_IMG" ]]; then
  echo "[-] '$INPUT_IMG' file not found"
  abort 1
fi
if [[ "$USER_JAVA_PATH" != "" ]]; then
  if  [ ! -f "$USER_JAVA_PATH" ]; then
    echo "[-] '$USER_JAVA_PATH' path not found"
    abort 1
  fi
  if [[ "$(basename "$USER_JAVA_PATH")" != "java" ]]; then
    echo "[-] Invalid java path"
    abort 1
  fi
fi

# Some business logic related checks
if [[ "$DEODEX_ALL" = true && $KEEP_DATA = false ]]; then
  echo "[!] It's pointless to deodex all if not keeping runtime generated data"
  echo "    After vendor generate finishes all files not part of configs will be deleted"
  abort 1
fi

# Check if output directory is AOSP root
if is_aosp_root "$OUTPUT_DIR"; then
  if [ "$KEEP_DATA" = true ]; then
    echo "[!] Cannot keep data when output directory is AOSP root - choose different path"
    abort 1
  fi
  AOSP_ROOT="$OUTPUT_DIR"
  OUTPUT_DIR="$TMP_WORK_DIR"
fi

# Resolve Java location
__JAVAPATH=""
__JAVADIR=""
__JAVA_HOME=""
if [[ "$USER_JAVA_PATH" != "" ]]; then
  __JAVAPATH=$(_realpath "$USER_JAVA_PATH")
  __JAVADIR=$(dirname "$__JAVAPATH")
  __JAVA_HOME="$__JAVAPATH"
else
  readonly __JAVALINK=$(which java)
  if [[ "$__JAVALINK" == "" ]]; then
    # We don't fail since Java is required only when oat2dex method is used
    echo "[-] Java not found in system"
  else
    if [[ "$HOST_OS" == "Darwin" ]]; then
      __JAVA_HOME="$(/usr/libexec/java_home)"
      __JAVADIR="$__JAVA_HOME/bin"
    else
      __JAVAPATH=$(_realpath "$__JAVALINK")
      __JAVADIR=$(dirname "$__JAVAPATH")
      __JAVA_HOME="$__JAVAPATH"
    fi
  fi
fi
export JAVA_HOME="$__JAVA_HOME"
export PATH="$__JAVADIR":$PATH

# Check if supported device
deviceOK=false
for devNm in "${SUPPORTED_DEVICES[@]}"
do
  if [[ "$devNm" == "$DEVICE" ]]; then
    deviceOK=true
  fi
done
if [ "$deviceOK" = false ]; then
  echo "[-] '$DEVICE' is not supported"
  abort 1
fi

# Prepare output dir structure
OUT_BASE="$OUTPUT_DIR/$DEVICE/$BUILDID"
if [ ! -d "$OUT_BASE" ]; then
  mkdir -p "$OUT_BASE"
fi
FACTORY_IMGS_DATA="$OUT_BASE/factory_imgs_data"
FACTORY_IMGS_R_DATA="$OUT_BASE/factory_imgs_repaired_data"
echo "[*] Setting output base to '$OUT_BASE'"

# Download images if not provided
factoryImgArchive=""
if [[ "$INPUT_IMG" == "" ]]; then

  # Factory image alias for devices with naming incompatibilities with AOSP
  if [[ "$DEVICE" == "flounder" && "$DEV_ALIAS" == "" ]]; then
    echo "[-] Building for flounder requires setting the device alias option - 'volantis' or 'volantisg'"
    abort 1
  fi
  if [[ "$DEV_ALIAS" == "" ]]; then
    DEV_ALIAS="$DEVICE"
  fi

  __extraArgs=""
  if [ $AUTO_TOS_ACCEPT = true ]; then
    __extraArgs="--yes"
  fi

 $DOWNLOAD_SCRIPT --device "$DEVICE" --alias "$DEV_ALIAS" \
       --buildID "$BUILDID" --output "$OUT_BASE" $__extraArgs || {
    echo "[-] Images download failed"
    abort 1
  }
  factoryImgArchive="$(find "$OUT_BASE" -iname "*$DEV_ALIAS*$BUILDID*.tgz" -or \
                       -iname "*$DEV_ALIAS*$BUILDID*.zip" | head -1)"
else
  factoryImgArchive="$INPUT_IMG"
fi

if [[ "$factoryImgArchive" == "" ]]; then
  echo "[-] Failed to locate factory image archive"
  abort 1
fi

# Clear old data if present & extract data from factory images
if [ -d "$FACTORY_IMGS_DATA" ]; then
  # Previous run might have been with --keep which keeps the mount-points. Check
  # if mounted & unmount if so.
  if mount | grep -q "$FACTORY_IMGS_DATA/system"; then
    unmount_raw_image "$FACTORY_IMGS_DATA/system"
  fi
  if mount | grep -q "$FACTORY_IMGS_DATA/vendor"; then
    unmount_raw_image "$FACTORY_IMGS_DATA/vendor"
  fi
  rm -rf "${FACTORY_IMGS_DATA:?}"/*
else
  mkdir -p "$FACTORY_IMGS_DATA"
fi

EXTRACT_SCRIPT_ARGS="--device "$DEVICE" --input "$factoryImgArchive" \
--output "$FACTORY_IMGS_DATA" \
--simg2img "$SCRIPTS_ROOT/hostTools/$HOST_OS/bin/simg2img""

if [ "$USE_DEBUGFS" = true ]; then
  EXTRACT_SCRIPT_ARGS+=" --debugfs"
fi

$EXTRACT_SCRIPT $EXTRACT_SCRIPT_ARGS || {
  echo "[-] Factory images data extract failed"
  abort 1
}

# system.img contents are different between Nexus & Pixel
SYSTEM_ROOT="$FACTORY_IMGS_DATA/system"
if [[ -d "$FACTORY_IMGS_DATA/system/system" && -f "$FACTORY_IMGS_DATA/system/system/build.prop" ]]; then
  SYSTEM_ROOT="$FACTORY_IMGS_DATA/system/system"
fi

# Extract API level from 'ro.build.version.sdk' field of system/build.prop
API_LEVEL=$(grep 'ro.build.version.sdk' "$SYSTEM_ROOT/build.prop" |
            cut -d '=' -f2 | tr '[:upper:]' '[:lower:]' || true)
if [[ "$API_LEVEL" == "" ]]; then
  echo "[-] Failed to extract API level from build.prop"
  abort 1
fi

echo "[*] Processing with 'API-$API_LEVEL $CONFIG' configuration"

# Generate unified readonly "proprietary-blobs.txt"
$GEN_BLOBS_LIST_SCRIPT --input "$FACTORY_IMGS_DATA/vendor" \
    --output "$SCRIPTS_ROOT/$DEVICE/$CONFIG" \
    --api "$API_LEVEL" \
    --conf-dir "$SCRIPTS_ROOT/$DEVICE/$CONFIG" || {
  echo "[-] 'proprietary-blobs.txt' generation failed"
  abort 1
}

# Repair bytecode from system partition
if [ -d "$FACTORY_IMGS_R_DATA" ]; then
  rm -rf "${FACTORY_IMGS_R_DATA:?}"/*
else
  mkdir -p "$FACTORY_IMGS_R_DATA"
fi

# Set bytecode repair method based on user arguments
if [ $SKIP_SYSDEOPT = true ]; then
  BYTECODE_REPAIR_METHOD="NONE"
elif [ $FORCE_SMALI = true ]; then
  BYTECODE_REPAIR_METHOD="SMALIDEODEX"
elif [ $FORCE_SMALIEX = true ]; then
  BYTECODE_REPAIR_METHOD="OAT2DEX"
elif [ $FORCE_OATDUMP = true ]; then
  BYTECODE_REPAIR_METHOD="OATDUMP"
else
  # Default choices based on API level
  if [ "$API_LEVEL" -le 23 ]; then
    BYTECODE_REPAIR_METHOD="OAT2DEX"
  elif [ "$API_LEVEL" -ge 24 ]; then
    BYTECODE_REPAIR_METHOD="OATDUMP"
  fi
fi

# OAT2DEX method is based on SmaliEx which is deprecated
if [[ "$BYTECODE_REPAIR_METHOD" == "OAT2DEX" && $API_LEVEL -ge 24 ]]; then
  echo "[-] SmaliEx OAT2DEX bytecode repair method is deprecated & not supporting API >= 24"
  abort 1
fi

# Adjust arguments of system repair script based on chosen method
case $BYTECODE_REPAIR_METHOD in
  "NONE")
    REPAIR_SCRIPT_ARG=""
    ;;
  "OATDUMP")
    if [ ! -f "$SCRIPTS_ROOT/hostTools/$HOST_OS/api-$API_LEVEL/bin/oatdump" ]; then
      echo "[*] First run detected - downloading oatdump host bin & lib dependencies"
      oatdump_prepare_env "$API_LEVEL"
    fi
    REPAIR_SCRIPT_ARG="--oatdump $SCRIPTS_ROOT/hostTools/$HOST_OS/api-$API_LEVEL/bin/oatdump \
                       --dexrepair $SCRIPTS_ROOT/hostTools/$HOST_OS/bin/dexrepair"

    # dex2oat is invoked from host with aggressive verifier flags. So there is a
    # high chance it will fail to preoptimize bytecode repaired with oatdump method.
    # Let the user know.
    if [ $FORCE_PREOPT = true ]; then
      echo "[!] AOSP builds might fail when LOCAL_DEX_PREOPT isn't false when using OATDUMP bytecode repair method"
    fi
    ;;
  "OAT2DEX")
    REPAIR_SCRIPT_ARG="--oat2dex $SCRIPTS_ROOT/hostTools/Java/oat2dex.jar"

    # LOCAL_DEX_PREOPT can be safely used so enable globally for /system
    FORCE_PREOPT=true
    ;;
  "SMALIDEODEX")
    if [ ! -f "$SCRIPTS_ROOT/hostTools/$HOST_OS/api-$API_LEVEL/bin/oatdump" ]; then
      echo "[*] First run detected - downloading oatdump host bin & lib dependencies"
      oatdump_prepare_env "$API_LEVEL"
    fi
    REPAIR_SCRIPT_ARG="--oatdump $SCRIPTS_ROOT/hostTools/$HOST_OS/api-$API_LEVEL/bin/oatdump \
                       --smali $SCRIPTS_ROOT/hostTools/Java/smali.jar \
                       --baksmali $SCRIPTS_ROOT/hostTools/Java/baksmali.jar"

    # LOCAL_DEX_PREOPT can be safely used so enable globally for /system
    FORCE_PREOPT=true
    ;;
  *)
    echo "[-] Invalid bytecode repair method"
    abort 1
    ;;
esac

# If deodex all not set provide a list of packages to repair
if [ $DEODEX_ALL = false ]; then
  REPAIR_SCRIPT_ARG+=" --bytecode-list $SCRIPTS_ROOT/$DEVICE/$CONFIG/bytecode-proprietary-api$API_LEVEL.txt"
fi

$REPAIR_SCRIPT --method "$BYTECODE_REPAIR_METHOD" --input "$SYSTEM_ROOT" \
     --output "$FACTORY_IMGS_R_DATA" $REPAIR_SCRIPT_ARG || {
  echo "[-] System partition bytecode repair failed"
  abort 1
}

# Bytecode under vendor partition doesn't require repair (at least for now)
# However, make it available to repaired data directory to have a single source
# for next script
ln -s "$FACTORY_IMGS_DATA/vendor" "$FACTORY_IMGS_R_DATA/vendor"

# Copy vendor partition image size as saved from $EXTRACT_SCRIPT script
# $VGEN_SCRIPT will fail over to last known working default if image size
# file not found when parsing data
cp "$FACTORY_IMGS_DATA/vendor_partition_size" "$FACTORY_IMGS_R_DATA"

# Make radio files available to vendor generate script
ln -s "$FACTORY_IMGS_DATA/radio" "$FACTORY_IMGS_R_DATA/radio"

VGEN_SCRIPT_EXTRA_ARGS=""
if [ $FORCE_PREOPT = true ]; then
  VGEN_SCRIPT_EXTRA_ARGS="--allow-preopt"
fi
if [ $FORCE_VIMG = true ]; then
  VGEN_SCRIPT_EXTRA_ARGS+=" --force-vimg"
fi
if [[ "$AOSP_ROOT" != "" ]]; then
  VGEN_SCRIPT_EXTRA_ARGS+=" --aosp-root $AOSP_ROOT"
fi

$VGEN_SCRIPT --input "$FACTORY_IMGS_R_DATA" \
  --output "$OUT_BASE" \
  --api "$API_LEVEL" \
  --conf-dir "$SCRIPTS_ROOT/$DEVICE/$CONFIG" \
  $VGEN_SCRIPT_EXTRA_ARGS || {
  echo "[-] Vendor generation failed"
  abort 1
}

if [ "$KEEP_DATA" = false ]; then
  if [ "$USE_DEBUGFS" = false ]; then
    # Mount points are present only when fuse-ext2 is used
    unmount_raw_image "$FACTORY_IMGS_DATA/system"
    unmount_raw_image "$FACTORY_IMGS_DATA/vendor"
  fi
  rm -rf "$FACTORY_IMGS_DATA"
  rm -rf "$FACTORY_IMGS_R_DATA"
fi

# If output dir is not AOSP SRC root print some user messages, otherwise the
# generate-vendor.sh script will rsync output intermediates
if [[ "$AOSP_ROOT" == "" ]]; then
  echo "[*] Import '$OUT_BASE/vendor' vendor blobs to AOSP root"
  echo "[*] Import '$OUT_BASE/vendor_overlay' vendor overlays to AOSP root"
fi

echo "[*] All actions completed successfully"
abort 0
