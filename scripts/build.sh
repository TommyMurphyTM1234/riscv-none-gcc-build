#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG} ]]
then
  set ${DEBUG} # Activate the expand mode if DEBUG is -x.
else
  DEBUG=""
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

# Script to build the GNU MCU Eclipse RISC-V GCC distribution packages.
#
# Developed on OS X 10.12 Sierra.
# Also tested on:
#   GNU/Linux Ubuntu 16.04 LTS
#   GNU/Linux Arch (Manjaro 16.08)
#
# The Windows and GNU/Linux packages are build using Docker containers.
# The build is structured in 2 steps, one running on the host machine
# and one running inside the Docker container.
#
# At first run, Docker will download/build 3 relatively large
# images (1-2GB) from Docker Hub.
#
# Prerequisites:
#
# - Docker
# - curl, git, automake, patch, tar, unzip, zip
#
# When running on OS X, a custom Homebrew is required to provide the 
# missing libraries and TeX binaries.
# 
# Without specifying a --xxx platform option, builds are assumed
# to be native on the GNU/Linux or macOS host.
# In this case all prerequisites must be met by the host. For example 
# for Ubuntu the following were needed:
#
# $ apt-get -y install automake cmake libtool libudev-dev patchelf bison flex texinfo texlive
#
# The GCC cross build requires several steps:
# - build the binutils & gdb
# - build a simple C compiler
# - build newlib, possibly multilib
# - build the final C/C++ compilers
#
# For the Windows target, we are in a 'canadian build' case; since
# the Windows binaries cannot be executed directly, the GNU/Linux 
# binaries are expected in the PATH.
#
# As a consequence, the Windows build is always done after the
# GNU/Linux build.
#
# The script also builds a size optimised version of the system libraries,
# similar to ARM **nano** version.
# In practical terms, this means a separate build of the compiler
# internal libraries, using `-Os -mcmodel=medany` instead of 
# `-O2 -mcmodel=medany` as for the regular libraries. It also means
# the `newlib` build with special configuration options to use 
# simpler `printf()` and memory management functions.
# 
# To resume a crashed build with the same timestamp, set
# DISTRIBUTION_FILE_DATE='yyyymmdd-HHMM' in the environment.
#
# To build in a custom folder, set WORK_FOLDER_PATH='xyz' 
# in the environment.
#
# Developer note:
# To make the resulting install folder relocatable (i.e. do not depend on
# an absolute location), the `--with-sysroot` must point to a sub-folder
# below `--prefix`.
#
# Configuration environment variables (see the script on how to use them):
#
# - WORK_FOLDER_PATH
# - DISTRIBUTION_FILE_DATE
# - APP_NAME
# - APP_UC_NAME
# - APP_LC_NAME
# - branding
# - gcc_target
# - gcc_arch
# - gcc_abi
# - BUILD_FOLDER_NAME
# - BUILD_FOLDER_PATH
# - DOWNLOAD_FOLDER_NAME
# - DOWNLOAD_FOLDER_PATH
# - DEPLOY_FOLDER_NAME
# - RELEASE_VERSION
# - BINUTILS_FOLDER_NAME
# - BINUTILS_GIT_URL
# - BINUTILS_GIT_BRANCH
# - BINUTILS_GIT_COMMIT
# - BINUTILS_VERSION
# - BINUTILS_TAG
# - BINUTILS_ARCHIVE_URL
# - BINUTILS_ARCHIVE_URL
# - BINUTILS_ARCHIVE_NAME
# - GCC_FOLDER_NAME
# - GCC_GIT_URL
# - GCC_GIT_BRANCH
# - GCC_GIT_COMMIT
# - GCC_VERSION
# - GCC_FOLDER_NAME
# - GCC_TAG
# - GCC_ARCHIVE_URL
# - GCC_ARCHIVE_NAME
# - GCC_MULTILIB
# - GCC_MULTILIB_FILE
# - NEWLIB_FOLDER_NAME
# - NEWLIB_GIT_URL
# - NEWLIB_GIT_BRANCH
# - NEWLIB_GIT_COMMIT
# - NEWLIB_VERSION
# - NEWLIB_FOLDER_NAME
# - NEWLIB_TAG
# - NEWLIB_ARCHIVE_URL
# - NEWLIB_ARCHIVE_NAME
#

# -----------------------------------------------------------------------------

# Mandatory definition.
APP_NAME=${APP_NAME:-"RISC-V Embedded GCC"}

# Used as part of file/folder paths.
APP_UC_NAME=${APP_UC_NAME:-"RISC-V Embedded GCC"}
APP_LC_NAME=${APP_LC_NAME:-"riscv-none-gcc"}

branding=${branding:-"GNU MCU Eclipse RISC-V Embedded GCC"}

# gcc_target=${gcc_target:-"riscv64-unknown-elf"}
gcc_target=${gcc_target:-"riscv-none-embed"}

gcc_arch=${gcc_arch:-"rv64imafdc"}
gcc_abi=${gcc_abi:-"lp64d"}

# Default to 2. Attempts to use 8 occasionally failed.
jobs="--jobs=2"

# On Parallels virtual machines, prefer host Work folder.
# Second choice are Work folders on secondary disks.
# Final choice is a Work folder in HOME.
if [ -d /media/psf/Home/Work ]
then
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"/media/psf/Home/Work/${APP_LC_NAME}"}
elif [ -d /media/${USER}/Work ]
then
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"/media/${USER}/Work/${APP_LC_NAME}"}
elif [ -d /media/Work ]
then
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"/media/Work/${APP_LC_NAME}"}
else
  # Final choice, a Work folder in HOME.
  WORK_FOLDER_PATH=${WORK_FOLDER_PATH:-"${HOME}/Work/${APP_LC_NAME}"}
fi

# ----- Define build constants. -----

BUILD_FOLDER_NAME=${BUILD_FOLDER_NAME:-"build"}
BUILD_FOLDER_PATH=${BUILD_FOLDER_PATH:-"${WORK_FOLDER_PATH}/${BUILD_FOLDER_NAME}"}

DOWNLOAD_FOLDER_NAME=${DOWNLOAD_FOLDER_NAME:-"download"}
DOWNLOAD_FOLDER_PATH=${DOWNLOAD_FOLDER_PATH:-"${WORK_FOLDER_PATH}/${DOWNLOAD_FOLDER_NAME}"}
DEPLOY_FOLDER_NAME=${DEPLOY_FOLDER_NAME:-"deploy"}

# ----- Define build Git constants. -----

PROJECT_GIT_FOLDER_NAME="riscv-none-gcc-build.git"
PROJECT_GIT_FOLDER_PATH="${WORK_FOLDER_PATH}/${PROJECT_GIT_FOLDER_NAME}"
PROJECT_GIT_DOWNLOADS_FOLDER_PATH="${HOME}/Downloads/${PROJECT_GIT_FOLDER_NAME}"
PROJECT_GIT_URL="https://github.com/gnu-mcu-eclipse/${PROJECT_GIT_FOLDER_NAME}"


# ----- Create Work folder. -----

echo
echo "Work folder: \"${WORK_FOLDER_PATH}\"."

mkdir -p "${WORK_FOLDER_PATH}"

# ----- Parse actions and command line options. -----

ACTION=""
DO_BUILD_WIN32=""
DO_BUILD_WIN64=""
DO_BUILD_LINUX32=""
DO_BUILD_LINUX64=""
DO_BUILD_OSX=""
helper_script_path=""
do_no_strip=""
multilib_flags="" # by default multilib is enabled
do_no_pdf=""
do_develop=""
do_use_gits=""

while [ $# -gt 0 ]
do
  case "$1" in

    clean|cleanall|pull|checkout-dev|checkout-stable|build-images|preload-images)
      ACTION="$1"
      shift
      ;;

    --win32|--window32)
      DO_BUILD_WIN32="y"
      shift
      ;;
    --win64|--windows64)
      DO_BUILD_WIN64="y"
      shift
      ;;
    --linux32|--deb32|--debian32)
      DO_BUILD_LINUX32="y"
      shift
      ;;
    --linux64|--deb64|--debian64)
      DO_BUILD_LINUX64="y"
      shift
      ;;
    --osx)
      DO_BUILD_OSX="y"
      shift
      ;;

    --all)
      DO_BUILD_WIN32="y"
      DO_BUILD_WIN64="y"
      DO_BUILD_LINUX32="y"
      DO_BUILD_LINUX64="y"
      DO_BUILD_OSX="y"
      shift
      ;;

    --helper-script)
      helper_script_path=$2
      shift 2
      ;;

    --disable-strip)
      do_no_strip="y"
      shift
      ;;

    --without-pdf)
      do_no_pdf="y"
      shift
      ;;

    --disable-multilib)
      multilib_flags="--disable-multilib"
      shift
      ;;

    --jobs)
      jobs="--jobs=$2"
      shift 2
      ;;

    --develop)
      do_develop="y"
      shift
      ;;

    --use-gits)
      do_use_gits="y"
      shift
      ;;

    --help)
      echo "Build the GNU MCU Eclipse ${APP_NAME} distributions."
      echo "Usage:"
      echo "    bash $0 helper_script [--win32] [--win64] [--linux32] [--linux64] [--osx] [--all] [clean|cleanall|build-images|preload-images] [--disable-strip] [--without-pdf] [--disable-multilib] [--develop] [--use-gits] [--jobs N] [--help]"
      echo
      exit 1
      ;;

    *)
      echo "Unknown action/option $1"
      exit 1
      ;;
  esac

done

# ----- Prepare build scripts. -----

build_script_path=$0
if [[ "${build_script_path}" != /* ]]
then
  # Make relative path absolute.
  build_script_path=$(pwd)/$0
fi

# Copy the current script to Work area, to later copy it into 
# the install folder.
mkdir -p "${WORK_FOLDER_PATH}/scripts"
cp "${build_script_path}" "${WORK_FOLDER_PATH}/scripts/build-${APP_LC_NAME}.sh"

# ----- Build helper. -----

if [ -z "${helper_script_path}" ]
then
  script_folder_path="$(dirname ${build_script_path})"
  script_folder_name="$(basename ${script_folder_path})"
  if [ \( "${script_folder_name}" == "scripts" \) \
    -a \( -f "${script_folder_path}/helper/build-helper.sh" \) ]
  then
    helper_script_path="${script_folder_path}/helper/build-helper.sh"
  elif [ \( "${script_folder_name}" == "scripts" \) \
    -a \( -d "${script_folder_path}/helper" \) ]
  then
    (
      cd "$(dirname ${script_folder_path})"
      git submodule update --init --recursive --remote
    )
    helper_script_path="${script_folder_path}/helper/build-helper.sh"
  elif [ -f "${WORK_FOLDER_PATH}/scripts/build-helper.sh" ]
  then
    helper_script_path="${WORK_FOLDER_PATH}/scripts/build-helper.sh"
  fi
else
  if [[ "${helper_script_path}" != /* ]]
  then
    # Make relative path absolute.
    helper_script_path="$(pwd)/${helper_script_path}"
  fi
fi

# Copy the current helper script to Work area, to later copy it into the install folder.
mkdir -p "${WORK_FOLDER_PATH}/scripts"
if [ "${helper_script_path}" != "${WORK_FOLDER_PATH}/scripts/build-helper.sh" ]
then
  cp "${helper_script_path}" "${WORK_FOLDER_PATH}/scripts/build-helper.sh"
fi

echo "Helper script: \"${helper_script_path}\"."
source "${helper_script_path}"

# ----- Get current date. -----

# Use the UTC date as version in the name of the distribution file.
do_host_get_current_date

touch "${WORK_FOLDER_PATH}/${DISTRIBUTION_FILE_DATE}"
echo
echo "DISTRIBUTION_FILE_DATE=\"${DISTRIBUTION_FILE_DATE}\""

# Be sure the changes are commited for the version to be used,
# otherwise the copied git will use the previous version.

# RELEASE_VERSION=${RELEASE_VERSION:-"7.1.1-2-20170912"}
RELEASE_VERSION=${RELEASE_VERSION:-"7.2.0-1-20171109"}

echo
echo "Preparing release ${RELEASE_VERSION}..."

# ----- Input archives -----

# The archives are available from dedicated Git repositories,
# part of the GNU MCU Eclipse project hosted on GitHub.
# Generally these projects follow the official RISC-V GCC 
# with updates after every RISC-V GCC public release.

BINUTILS_PROJECT_NAME="riscv-binutils-gdb"

if [ "${do_use_gits}" == "y" ]
then
  BINUTILS_FOLDER_NAME=${BINUTILS_FOLDER_NAME:-"${BINUTILS_PROJECT_NAME}.git"}

  BINUTILS_GIT_URL=${BINUTILS_GIT_URL:-"https://github.com/gnu-mcu-eclipse/riscv-binutils-gdb.git"}
  BINUTILS_GIT_BRANCH=${BINUTILS_GIT_BRANCH:-"riscv-binutils-2.29-gme"}
  # June 17, 2017
  BINUTILS_GIT_COMMIT=${BINUTILS_GIT_COMMIT:-"1687da01bdcb15f6804787d4c9b2d1a5d92f7b1a"}
else
  BINUTILS_VERSION=${BINUTILS_VERSION:-"${RELEASE_VERSION}"}
  BINUTILS_FOLDER_NAME="${BINUTILS_PROJECT_NAME}-${BINUTILS_VERSION}"

  BINUTILS_TAG=${BINUTILS_TAG:-"v${BINUTILS_VERSION}"}
  BINUTILS_ARCHIVE_URL=${BINUTILS_ARCHIVE_URL:-"https://github.com/gnu-mcu-eclipse/${BINUTILS_PROJECT_NAME}/archive/${BINUTILS_TAG}.tar.gz"}
  BINUTILS_ARCHIVE_NAME=${BINUTILS_ARCHIVE_NAME:-"${BINUTILS_FOLDER_NAME}.tar.gz"}

  BINUTILS_GIT_URL=""
fi

GCC_PROJECT_NAME="riscv-none-gcc"

if [ "${do_use_gits}" == "y" ]
then
  GCC_FOLDER_NAME=${GCC_FOLDER_NAME:-"${GCC_PROJECT_NAME}.git"}

  GCC_GIT_URL=${GCC_GIT_URL:-"https://github.com/gnu-mcu-eclipse/riscv-none-gcc.git"}
  GCC_GIT_BRANCH=${GCC_GIT_BRANCH:-"riscv-gcc-7.2.0-gme"}
  GCC_GIT_COMMIT=${GCC_GIT_COMMIT:-"ab6b9b49de587375797fc0a587bc1d42d270584f"}
else
  GCC_VERSION=${GCC_VERSION:-"${RELEASE_VERSION}"}
  GCC_FOLDER_NAME=${GCC_FOLDER_NAME:-"${GCC_PROJECT_NAME}-${GCC_VERSION}"}

  GCC_TAG=${GCC_TAG:-"v${GCC_VERSION}"}
  GCC_ARCHIVE_URL=${GCC_ARCHIVE_URL:-"https://github.com/gnu-mcu-eclipse/${GCC_PROJECT_NAME}/archive/${GCC_TAG}.tar.gz"}
  GCC_ARCHIVE_NAME=${GCC_ARCHIVE_NAME:-"${GCC_FOLDER_NAME}.tar.gz"}

  GCC_GIT_URL=""
fi

# The default is:
# rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--
# Add 'rv32imaf-ilp32f--'. 
GCC_MULTILIB=${GCC_MULTILIB:-(rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imaf-ilp32f-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--)}
GCC_MULTILIB_FILE=${GCC_MULTILIB_FILE:-"t-elf-multilib"}

NEWLIB_PROJECT_NAME="riscv-newlib"

if [ "${do_use_gits}" == "y" ]
then
  NEWLIB_FOLDER_NAME=${NEWLIB_FOLDER_NAME:-"${NEWLIB_PROJECT_NAME}.git"}
  
  NEWLIB_GIT_URL=${NEWLIB_GIT_URL:-"https://github.com/gnu-mcu-eclipse/riscv-newlib.git"}
  NEWLIB_GIT_BRANCH=${NEWLIB_GIT_BRANCH:-"riscv-newlib-2.5.0-gme"}
  NEWLIB_GIT_COMMIT=${NEWLIB_GIT_COMMIT:-"5b38d671e29e125b5c98c0e310714d8b64117ec7"}
else
  NEWLIB_VERSION=${NEWLIB_VERSION:-"${RELEASE_VERSION}"}
  NEWLIB_FOLDER_NAME=${NEWLIB_FOLDER_NAME:-"${NEWLIB_PROJECT_NAME}-${NEWLIB_VERSION}"}

  NEWLIB_TAG=${NEWLIB_TAG:-"v${NEWLIB_VERSION}"}
  NEWLIB_ARCHIVE_URL=${NEWLIB_ARCHIVE_URL:-"https://github.com/gnu-mcu-eclipse/${NEWLIB_PROJECT_NAME}/archive/${NEWLIB_TAG}.tar.gz"}
  NEWLIB_ARCHIVE_NAME=${NEWLIB_ARCHIVE_NAME:-"${NEWLIB_FOLDER_NAME}.tar.gz"}

  NEWLIB_GIT_URL=""
fi

# ----- Libraries sources. -----

# For updates, please check the corresponding pages.

# http://zlib.net
# https://sourceforge.net/projects/libpng/files/zlib/

# LIBZ_VERSION="1.2.11" # 2017-01-16

# LIBZ_FOLDER="zlib-${LIBZ_VERSION}"
# LIBZ_ARCHIVE="${LIBZ_FOLDER}.tar.gz"
# LIBZ_URL="https://sourceforge.net/projects/libpng/files/zlib/${LIBZ_VERSION}/${LIBZ_ARCHIVE}"


# https://gmplib.org
# https://gmplib.org/download/gmp/
# https://gmplib.org/download/gmp/gmp-6.1.0.tar.bz2

# GMP_VERSION="6.1.0"
GMP_VERSION="6.1.2"

GMP_FOLDER="gmp-${GMP_VERSION}"
GMP_ARCHIVE="${GMP_FOLDER}.tar.bz2"
GMP_URL="https://gmplib.org/download/gmp/${GMP_ARCHIVE}"


# http://www.mpfr.org
# http://www.mpfr.org/mpfr-3.1.5/mpfr-3.1.5.tar.bz2

# MPFR_VERSION="3.1.4"
MPFR_VERSION="3.1.6"

MPFR_FOLDER="mpfr-${MPFR_VERSION}"
MPFR_ARCHIVE="${MPFR_FOLDER}.tar.bz2"
MPFR_URL="http://www.mpfr.org/${MPFR_FOLDER}/${MPFR_ARCHIVE}"


# http://www.multiprecision.org/index.php?prog=mpc
# ftp://ftp.gnu.org/gnu/mpc/mpc-1.0.3.tar.gz

MPC_VERSION="1.0.3"

MPC_FOLDER="mpc-${MPC_VERSION}"
MPC_ARCHIVE="${MPC_FOLDER}.tar.gz"
MPC_URL="ftp://ftp.gnu.org/gnu/mpc/${MPC_ARCHIVE}"

# http://isl.gforge.inria.fr
# http://isl.gforge.inria.fr/isl-0.16.1.tar.bz2

# ISL_VERSION="0.16.1"
ISL_VERSION="0.18"

ISL_FOLDER="isl-${ISL_VERSION}"
ISL_ARCHIVE="${ISL_FOLDER}.tar.bz2"
ISL_URL="http://isl.gforge.inria.fr/${ISL_ARCHIVE}"

# https://libexpat.github.io
# https://github.com/libexpat/libexpat/releases

EXPAT_VERSION="2.2.5"

EXPAT_FOLDER="expat-${EXPAT_VERSION}"
EXPAT_ARCHIVE="${EXPAT_FOLDER}.tar.bz2"
EXPAT_RELEASE="R_$(echo ${EXPAT_VERSION} | sed -e 's|[.]|_|g')"
EXPAT_URL="https://github.com/libexpat/libexpat/releases/download/${EXPAT_RELEASE}/${EXPAT_ARCHIVE}"

# ----- Process actions. -----

if [ \( "${ACTION}" == "clean" \) -o \( "${ACTION}" == "cleanall" \) ]
then
  # Remove most build and temporary folders.
  echo
  if [ "${ACTION}" == "cleanall" ]
  then
    echo "Remove all the build folders..."
  else
    echo "Remove most of the build folders (except output)..."
  fi

  rm -rf "${BUILD_FOLDER_PATH}"
  rm -rf "${WORK_FOLDER_PATH}/install"
  rm -rf "${WORK_FOLDER_PATH}/scripts"

  rm -rf "${WORK_FOLDER_PATH}/${GMP_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${MPFR_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${MPC_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${ISL_FOLDER}"
  rm -rf "${WORK_FOLDER_PATH}/${EXPAT_FOLDER}"

  if [ -z "${do_use_gits}" ]
  then
    rm -rf "${WORK_FOLDER_PATH}/${BINUTILS_FOLDER_NAME}"
    rm -rf "${WORK_FOLDER_PATH}/${GCC_FOLDER_NAME}"
    rm -rf "${WORK_FOLDER_PATH}/${NEWLIB_FOLDER_NAME}"
  fi

  if [ "${ACTION}" == "cleanall" ]
  then
    rm -rf "${WORK_FOLDER_PATH}/${BINUTILS_FOLDER_NAME}"
    rm -rf "${WORK_FOLDER_PATH}/${GCC_FOLDER_NAME}"
    rm -rf "${WORK_FOLDER_PATH}/${NEWLIB_FOLDER_NAME}"

    rm -rf "${PROJECT_GIT_FOLDER_PATH}"
    rm -rf "${WORK_FOLDER_PATH}/${DEPLOY_FOLDER_NAME}"
  fi

  echo
  echo "Clean completed. Proceed with a regular build."

  exit 0
fi

# ----- Start build. -----

do_host_start_timer

do_host_detect

# ----- Process "preload-images" action. -----

if [ "${ACTION}" == "preload-images" ]
then
  do_host_prepare_docker

  echo
  echo "Check/Preload Docker images..."

  echo
  docker run --interactive --tty ilegeul/debian:9-gnu-mcu-eclipse \
  lsb_release --description --short

  echo
  docker run --interactive --tty ilegeul/debian32:9-gnu-mcu-eclipse \
  lsb_release --description --short

  echo
  docker images

  do_host_stop_timer

  exit 0
fi

# ----- Process "build-images" action. -----

if [ "${ACTION}" == "build-images" ]
then
  do_host_prepare_docker

  # Remove most build and temporary folders.
  echo
  echo "Build Docker images..."

  # Be sure it will not crash on errors, in case the images are already there.
  set +e

  docker build --tag "ilegeul/debian32:9-gnu-mcu-eclipse" \
  https://github.com/ilg-ul/docker/raw/master/debian32/9-gnu-mcu-eclipse/Dockerfile

  docker build --tag "ilegeul/debian:9-gnu-mcu-eclipse" \
  https://github.com/ilg-ul/docker/raw/master/debian/9-gnu-mcu-eclipse/Dockerfile

  docker images

  do_host_stop_timer

  exit 0
fi


# ----- Prepare prerequisites. -----

do_host_prepare_prerequisites


# ----- Prepare Docker, if needed. -----

if [ -n "${DO_BUILD_WIN32}${DO_BUILD_WIN64}${DO_BUILD_LINUX32}${DO_BUILD_LINUX64}" ]
then
  do_host_prepare_docker
fi

# ----- Check some more prerequisites. -----

echo
echo "Checking host tar..."
tar --version

echo
echo "Checking host unzip..."
unzip | grep UnZip

# ----- Get the project git repository. -----

if [ -d "${PROJECT_GIT_DOWNLOADS_FOLDER_PATH}" ]
then

  # If the folder is already present in Downloads, copy it.
  echo "Copying ${PROJECT_GIT_FOLDER_NAME} from Downloads (be sure it is commited!)..."
  rm -rf "${PROJECT_GIT_FOLDER_PATH}"
  mkdir -p "${PROJECT_GIT_FOLDER_PATH}"
  git clone "${PROJECT_GIT_DOWNLOADS_FOLDER_PATH}" "${PROJECT_GIT_FOLDER_PATH}"

else

  if [ ! -d "${PROJECT_GIT_FOLDER_PATH}" ]
  then

    cd "${WORK_FOLDER_PATH}"

    echo "If asked, enter ${USER} GitHub password for git clone"
    git clone "${PROJECT_GIT_URL}" "${PROJECT_GIT_FOLDER_PATH}"

  fi

fi


# ----- Get BINUTILS & GDB. -----

if [ ! -d "${WORK_FOLDER_PATH}/${BINUTILS_FOLDER_NAME}" ]
then
  if [ -n "${BINUTILS_GIT_URL}" ]
  then
    cd "${WORK_FOLDER_PATH}"
    echo
    git clone --branch="${BINUTILS_GIT_BRANCH}" "${BINUTILS_GIT_URL}" \
      "${BINUTILS_FOLDER_NAME}"
    if [ -n "${BINUTILS_GIT_COMMIT}" ]
    then
      cd "${BINUTILS_FOLDER_NAME}"
      git checkout -qf "${BINUTILS_GIT_COMMIT}"
    fi
  elif [ -n "${BINUTILS_ARCHIVE_URL}" ]
  then
    if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${BINUTILS_ARCHIVE_NAME}" ]
    then
      mkdir -p "${DOWNLOAD_FOLDER_PATH}"

      # Download BINUTILS archive.
      cd "${DOWNLOAD_FOLDER_PATH}"
      echo
      echo "Downloading '${BINUTILS_ARCHIVE_URL}'..."
      curl --fail -L "${BINUTILS_ARCHIVE_URL}" --output "${BINUTILS_ARCHIVE_NAME}"
    fi

    # Unpack BINUTILS.
    cd "${WORK_FOLDER_PATH}"
    echo
    echo "Unpacking '${BINUTILS_ARCHIVE_NAME}'..."
    tar -xf "${DOWNLOAD_FOLDER_PATH}/${BINUTILS_ARCHIVE_NAME}"
  fi
fi


# ----- Get GCC. -----

if [ ! -d "${WORK_FOLDER_PATH}/${GCC_FOLDER_NAME}" ]
then
  if [ -n "${GCC_GIT_URL}" ]
  then
    cd "${WORK_FOLDER_PATH}"
    echo
    git clone --branch="${GCC_GIT_BRANCH}" "${GCC_GIT_URL}" \
      "${GCC_FOLDER_NAME}"
    if [ -n "${GCC_GIT_COMMIT}" ]
    then
      cd "${GCC_FOLDER_NAME}"
      git checkout -qf "${GCC_GIT_COMMIT}"
    fi
  elif [ -n "${GCC_ARCHIVE_URL}" ]
  then
    if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${GCC_ARCHIVE_NAME}" ]
    then
      mkdir -p "${DOWNLOAD_FOLDER_PATH}"

      # Download GCC archive.
      cd "${DOWNLOAD_FOLDER_PATH}"
      echo
      echo "Downloading '${GCC_ARCHIVE_URL}'..."
      curl --fail -L "${GCC_ARCHIVE_URL}" --output "${GCC_ARCHIVE_NAME}"
    fi

    # Unpack GCC.
    cd "${WORK_FOLDER_PATH}"
    echo
    echo "Unpacking '${GCC_ARCHIVE_NAME}'..."
    tar -xf "${DOWNLOAD_FOLDER_PATH}/${GCC_ARCHIVE_NAME}"
  fi
fi


# ----- Get NEWLIB. -----

if [ ! -d "${WORK_FOLDER_PATH}/${NEWLIB_FOLDER_NAME}" ]
then
  if [ -n "${NEWLIB_GIT_URL}" ]
  then
    cd "${WORK_FOLDER_PATH}"
    echo
    git clone --branch="${NEWLIB_GIT_BRANCH}" "${NEWLIB_GIT_URL}" \
      "${NEWLIB_FOLDER_NAME}"
    if [ -n "${NEWLIB_GIT_COMMIT}" ]
    then
      cd "${NEWLIB_FOLDER_NAME}"
      git checkout -qf "${NEWLIB_GIT_COMMIT}"
    fi
  elif [ -n "${NEWLIB_ARCHIVE_URL}" ]
  then
    if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${NEWLIB_ARCHIVE_NAME}" ]
    then
      mkdir -p "${DOWNLOAD_FOLDER_PATH}"

      # Download NEWLIB archive.
      cd "${DOWNLOAD_FOLDER_PATH}"
      echo
      echo "Downloading '${NEWLIB_ARCHIVE_URL}'..."
      curl --fail -L "${NEWLIB_ARCHIVE_URL}" --output "${NEWLIB_ARCHIVE_NAME}"
    fi

    # Unpack NEWLIB.
    cd "${WORK_FOLDER_PATH}"
    echo
    echo "Unpacking '${NEWLIB_ARCHIVE_NAME}'..."
    tar -xf "${DOWNLOAD_FOLDER_PATH}/${NEWLIB_ARCHIVE_NAME}"
  fi
fi


# ----- Get GMP. -----

if [ ! -d "${WORK_FOLDER_PATH}/${GMP_FOLDER}" ]
then
  if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${GMP_ARCHIVE}" ]
  then
    mkdir -p "${DOWNLOAD_FOLDER_PATH}"

    # Download the GMP library.
    cd "${DOWNLOAD_FOLDER_PATH}"
    echo
    echo "Downloading '${GMP_URL}'..."
    curl --fail -L "${GMP_URL}" --output "${GMP_ARCHIVE}"
  fi

  # Unpack GMP.
  cd "${WORK_FOLDER_PATH}"
  echo
  echo "Unpacking '${GMP_ARCHIVE}'..."
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${GMP_ARCHIVE}"
fi


# ----- Get MPFR. -----

if [ ! -d "${WORK_FOLDER_PATH}/${MPFR_FOLDER}" ]
then
  if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${MPFR_ARCHIVE}" ]
  then
    mkdir -p "${DOWNLOAD_FOLDER_PATH}"

    # Download the MPFR library.
    cd "${DOWNLOAD_FOLDER_PATH}"
    echo
    echo "Downloading '${MPFR_URL}'..."
    curl --fail -L "${MPFR_URL}" --output "${MPFR_ARCHIVE}"
  fi

  # Unpack MPFR.
  cd "${WORK_FOLDER_PATH}"
  echo
  echo "Unpacking '${MPFR_ARCHIVE}'..."
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${MPFR_ARCHIVE}"
fi


# ----- Get MPC. -----

if [ ! -d "${WORK_FOLDER_PATH}/${MPC_FOLDER}" ]
then
  if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${MPC_ARCHIVE}" ]
  then
    mkdir -p "${DOWNLOAD_FOLDER_PATH}"

    # Download the MPC library.
    cd "${DOWNLOAD_FOLDER_PATH}"
    echo
    echo "Downloading '${MPC_URL}'..."
    curl --fail -L "${MPC_URL}" --output "${MPC_ARCHIVE}"
  fi

  # Unpack MPC.
  cd "${WORK_FOLDER_PATH}"
  echo
  echo "Unpacking '${MPC_ARCHIVE}'..."
  tar -xzvf "${DOWNLOAD_FOLDER_PATH}/${MPC_ARCHIVE}"
fi


# ----- Get ISL. -----

if [ ! -d "${WORK_FOLDER_PATH}/${ISL_FOLDER}" ]
then
  if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${ISL_ARCHIVE}" ]
  then
    mkdir -p "${DOWNLOAD_FOLDER_PATH}"

    # Download the ISL library.
    cd "${DOWNLOAD_FOLDER_PATH}"
    echo
    echo "Downloading '${ISL_URL}'..."
    curl --fail -L "${ISL_URL}" --output "${ISL_ARCHIVE}"
  fi

  # Unpack ISL.
  cd "${WORK_FOLDER_PATH}"
  echo
  echo "Unpacking '${ISL_ARCHIVE}'..."
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${ISL_ARCHIVE}"
fi

# ----- Get EXPAT. -----

if [ ! -d "${WORK_FOLDER_PATH}/${EXPAT_FOLDER}" ]
then
  if [ ! -f "${DOWNLOAD_FOLDER_PATH}/${EXPAT_ARCHIVE}" ]
  then
    mkdir -p "${DOWNLOAD_FOLDER_PATH}"

    # Download the EXPAT library.
    cd "${DOWNLOAD_FOLDER_PATH}"
    echo
    echo "Downloading '${EXPAT_URL}'..."
    curl --fail -L "${EXPAT_URL}" --output "${EXPAT_ARCHIVE}"
  fi

  # Unpack EXPAT.
  cd "${WORK_FOLDER_PATH}"
  echo
  echo "Unpacking '${EXPAT_ARCHIVE}'..."
  tar -xjvf "${DOWNLOAD_FOLDER_PATH}/${EXPAT_ARCHIVE}"
fi

# v===========================================================================v
# Create the build script (needs to be separate for Docker).

script_name="inner-build.sh"
script_file_path="${WORK_FOLDER_PATH}/scripts/${script_name}"

rm -f "${script_file_path}"
mkdir -p "$(dirname ${script_file_path})"
touch "${script_file_path}"

# Note: __EOF__ is quoted to prevent substitutions here.
cat <<'__EOF__' >> "${script_file_path}"
#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG} ]]
then
  set -x # Activate the expand mode if DEBUG is anything but empty.
else
  DEBUG=""
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

__EOF__
# The above marker must start in the first column.

# Note: __EOF__ is not quoted to allow local substitutions.
cat <<__EOF__ >> "${script_file_path}"

APP_NAME="${APP_NAME}"
APP_LC_NAME="${APP_LC_NAME}"
APP_UC_NAME="${APP_UC_NAME}"
DISTRIBUTION_FILE_DATE="${DISTRIBUTION_FILE_DATE}"
PROJECT_GIT_FOLDER_NAME="${PROJECT_GIT_FOLDER_NAME}"
BINUTILS_FOLDER_NAME="${BINUTILS_FOLDER_NAME}"
GCC_FOLDER_NAME="${GCC_FOLDER_NAME}"
NEWLIB_FOLDER_NAME="${NEWLIB_FOLDER_NAME}"

DEPLOY_FOLDER_NAME="${DEPLOY_FOLDER_NAME}"

GMP_FOLDER="${GMP_FOLDER}"
GMP_ARCHIVE="${GMP_ARCHIVE}"

MPFR_FOLDER="${MPFR_FOLDER}"
MPFR_ARCHIVE="${MPFR_ARCHIVE}"

MPC_FOLDER="${MPC_FOLDER}"
MPC_ARCHIVE="${MPC_ARCHIVE}"

ISL_FOLDER="${ISL_FOLDER}"
ISL_ARCHIVE="${ISL_ARCHIVE}"

EXPAT_FOLDER="${EXPAT_FOLDER}"

do_no_strip="${do_no_strip}"
do_no_pdf="${do_no_pdf}"

gcc_target="${gcc_target}"
gcc_arch="${gcc_arch}"
gcc_abi="${gcc_abi}"

GCC_MULTILIB=${GCC_MULTILIB}
GCC_MULTILIB_FILE="${GCC_MULTILIB_FILE}"

multilib_flags="${multilib_flags}"
jobs="${jobs}"

branding="${branding}"

# Cannot use medlow with 64 bits, so both must be medany.
cflags_optimizations_for_target="-O2 -mcmodel=medany"
cflags_optimizations_nano_for_target="-Os -mcmodel=medany"

__EOF__
# The above marker must start in the first column.

# Propagate DEBUG to guest.
set +u
if [[ ! -z ${DEBUG} ]]
then
  echo "DEBUG=${DEBUG}" "${script_file_path}"
  echo
fi
set -u

# Note: __EOF__ is quoted to prevent substitutions here.
cat <<'__EOF__' >> "${script_file_path}"

PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-""}

# For just in case.
export LC_ALL="C"
# export CONFIG_SHELL="/bin/bash"
export CONFIG_SHELL="/bin/sh"

script_name="$(basename "$0")"
args="$@"
docker_container_name=""
extra_path=""

while [ $# -gt 0 ]
do
  case "$1" in
    --container-build-folder)
      container_build_folder_path="$2"
      shift 2
      ;;

    --container-install-folder)
      container_install_folder_path="$2"
      shift 2
      ;;

    --container-output-folder)
      container_output_folder_path="$2"
      shift 2
      ;;

    --shared-install-folder)
      shared_install_folder_path="$2"
      shift 2
      ;;


    --docker-container-name)
      docker_container_name="$2"
      shift 2
      ;;

    --target-os)
      target_os="$2"
      shift 2
      ;;

    --target-bits)
      target_bits="$2"
      shift 2
      ;;

    --work-folder)
      work_folder_path="$2"
      shift 2
      ;;

    --distribution-folder)
      distribution_folder="$2"
      shift 2
      ;;

    --download-folder)
      download_folder="$2"
      shift 2
      ;;

    --helper-script)
      helper_script_path="$2"
      shift 2
      ;;

    --group-id)
      group_id="$2"
      shift 2
      ;;

    --user-id)
      user_id="$2"
      shift 2
      ;;

    --host-uname)
      host_uname="$2"
      shift 2
      ;;

    --extra-path)
      extra_path="$2"
      shift 2
      ;;

    *)
      echo "Unknown option $1, exit."
      exit 1
  esac
done

# Run the helper script in this shell, to get the support functions.
source "${helper_script_path}"

if [ -f "/opt/xbb/xbb.sh" ]
then
  source "/opt/xbb/xbb.sh"

  xbb_activate

  # Don't forget to add `-static-libstdc++` to app LDFLAGS,
  # otherwise the final executable will have a reference to 
  # a wrong `libstdc++.so.6`.
fi

do_container_detect

mkdir -p "${install_folder}"
start_stamp_file="${install_folder}/stamp_started"
if [ ! -f "${start_stamp_file}" ]
then
  touch "${start_stamp_file}"
fi

download_folder_path=${download_folder_path:-"${work_folder_path}/download"}
git_folder_path="${work_folder_path}/${PROJECT_GIT_FOLDER_NAME}"
distribution_file_version=$(cat "${git_folder_path}/gnu-mcu-eclipse/VERSION")-${DISTRIBUTION_FILE_DATE}

app_prefix="${install_folder}/${APP_LC_NAME}"
app_prefix_doc="${app_prefix}/share/doc"

app_prefix_nano="${app_prefix}-nano"
app_prefix_nano_doc="${app_prefix_nano}/share/doc"

# The \x2C is a comma in hex; without this trick the regular expression
# that processes this string in the Makefile, silently fails and the 
# bfdver.h file remains empty.
branding="${branding}\x2C ${target_bits}-bits"

if [ -f "${extra_path}/${gcc_target}-gcc" ]
then
  PATH="${extra_path}":${PATH}
  echo ${PATH}
fi

mkdir -p "${build_folder_path}"
cd "${build_folder_path}"


# ----- Test if various tools are present -----

echo
echo "Checking automake..."
automake --version 2>/dev/null | grep automake

if [ "${target_os}" != "osx" ]
then
  echo "Checking readelf..."
  readelf --version | grep readelf
fi

if [ "${target_os}" == "win" ]
then
  echo "Checking ${cross_compile_prefix}-gcc..."
  ${cross_compile_prefix}-gcc --version 2>/dev/null | egrep -e 'gcc|clang'

  echo "Checking unix2dos..."
  unix2dos --version 2>&1 | grep unix2dos

  # echo "Checking makensis..."
  # echo "makensis $(makensis -VERSION)"

  # apt-get --yes install zip

  echo "Checking zip..."
  zip -v | grep "This is Zip"
else
  echo "Checking gcc..."
  gcc --version 2>/dev/null | egrep -e 'gcc|clang'
fi

if [ "${target_os}" == "linux" ]
then
  echo "Checking patchelf..."
  patchelf --version
fi

if [ -z "${do_no_pdf}" ]
then
  echo "Checking makeinfo..."
  makeinfo --version | grep 'GNU texinfo'
  makeinfo_ver=$(makeinfo --version | grep 'GNU texinfo' | sed -e 's/.*) //' -e 's/\..*//')
  if [ "${makeinfo_ver}" -lt "6" ]
  then
    echo "makeinfo too old, abort."
    exit 1
  fi
fi

echo "Checking bison..."
bison --version

echo "Checking flex..."
flex --version

echo "Checking shasum..."
shasum --version

# ----- Build and install the GMP library. -----

gmp_stamp_file="${build_folder_path}/${GMP_FOLDER}/stamp-install-completed"

if [ ! -f "${gmp_stamp_file}" ]
then

  rm -rf "${build_folder_path}/${GMP_FOLDER}"
  mkdir -p "${build_folder_path}/${GMP_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running gmp configure..."

  cd "${build_folder_path}/${GMP_FOLDER}"

  # ABI is mandatory, otherwise configure fails on 32-bits.
  # (see https://gmplib.org/manual/ABI-and-ISA.html)

  if [ "${target_os}" == "win" ]
  then
    (
      export CFLAGS="-Wno-unused-value -Wno-empty-translation-unit -Wno-tautological-compare -pipe -ffunction-sections -fdata-sections"
      export CPPFLAGS="-I${install_folder}/include"
      export LDFLAGS="-L${install_folder}/lib"
      export ABI="${target_bits}"
      
      bash "${work_folder_path}/${GMP_FOLDER}/configure" --help
      bash "${work_folder_path}/${GMP_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --build="$(uname -m)-linux-gnu" \
        --host="${cross_compile_prefix}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
  then
    (
      export CFLAGS="-Wno-unused-value -Wno-empty-translation-unit -Wno-tautological-compare -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      export ABI="${target_bits}" 
      
      bash "${work_folder_path}/${GMP_FOLDER}/configure" --help
      bash "${work_folder_path}/${GMP_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  fi

  echo
  echo "Running gmp make..."

  # Build.
  # make clean
  make ${jobs}
  make install-strip

  touch "${gmp_stamp_file}"
fi

# ----- Build and install the MPFR library. -----

mpfr_stamp_file="${build_folder_path}/${MPFR_FOLDER}/stamp-install-completed"

if [ ! -f "${mpfr_stamp_file}" ]
then

  rm -rf "${build_folder_path}/${MPFR_FOLDER}"
  mkdir -p "${build_folder_path}/${MPFR_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running mpfr configure..."

  cd "${build_folder_path}/${MPFR_FOLDER}"

  if [ "${target_os}" == "win" ]
  then
    (
      export CFLAGS="-pipe -ffunction-sections -fdata-sections"
      export CPPFLAGS="-I${install_folder}/include"
      export LDFLAGS="-L${install_folder}/lib"
      
      bash "${work_folder_path}/${MPFR_FOLDER}/configure" --help
      bash "${work_folder_path}/${MPFR_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --build="$(uname -m)-linux-gnu" \
        --host="${cross_compile_prefix}" \
        \
        --disable-warnings \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
  then
    (
      export CFLAGS="-m${target_bits} -pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${MPFR_FOLDER}/configure" --help
      bash "${work_folder_path}/${MPFR_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --disable-warnings \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  fi

  echo
  echo "Running mpfr make..."

  # Build.
  # make clean
  make ${jobs}
  make install-strip

  touch "${mpfr_stamp_file}"
fi

# ----- Build and install the MPC library. -----

mpc_stamp_file="${build_folder_path}/${MPC_FOLDER}/stamp-install-completed"

if [ ! -f "${mpc_stamp_file}" ]
then

  rm -rf "${build_folder_path}/${MPC_FOLDER}"
  mkdir -p "${build_folder_path}/${MPC_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running mpc configure..."

  cd "${build_folder_path}/${MPC_FOLDER}"

  if [ "${target_os}" == "win" ]
  then
    (
      export CFLAGS="-pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${MPC_FOLDER}/configure" --help
      bash "${work_folder_path}/${MPC_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --build="$(uname -m)-linux-gnu" \
        --host="${cross_compile_prefix}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
  then
    (
      export CFLAGS="-m${target_bits} -pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${MPC_FOLDER}/configure" --help
      bash "${work_folder_path}/${MPC_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  fi

  echo
  echo "Running mpc make..."

  # Build.
  # make clean
  make ${jobs}
  make install-strip

  touch "${mpc_stamp_file}"
fi

# ----- Build and install the ISL library. -----

isl_stamp_file="${build_folder_path}/${ISL_FOLDER}/stamp-install-completed"

if [ ! -f "${isl_stamp_file}" ]
then

  rm -rf "${build_folder_path}/${ISL_FOLDER}"
  mkdir -p "${build_folder_path}/${ISL_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running isl configure..."

  cd "${build_folder_path}/${ISL_FOLDER}"

  if [ "${target_os}" == "win" ]
  then
    (
      export CFLAGS="-Wno-dangling-else -pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${ISL_FOLDER}/configure" --help
      bash "${work_folder_path}/${ISL_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --build="$(uname -m)-linux-gnu" \
        --host="${cross_compile_prefix}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
  then
    (
      export CFLAGS="-Wno-dangling-else -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${ISL_FOLDER}/configure" --help
      bash "${work_folder_path}/${ISL_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  fi

  echo
  echo "Running isl make..."

  # Build.
  # make clean
  make ${jobs}
  make install-strip

  touch "${isl_stamp_file}"
fi

# ----- Build and install the EXPAT library. -----

expat_stamp_file="${build_folder_path}/${EXPAT_FOLDER}/stamp-install-completed"

if [ ! -f "${expat_stamp_file}" ]
then

  rm -rf "${build_folder_path}/${EXPAT_FOLDER}"
  mkdir -p "${build_folder_path}/${EXPAT_FOLDER}"

  mkdir -p "${install_folder}"

  echo
  echo "Running expat configure..."

  cd "${build_folder_path}/${EXPAT_FOLDER}"

  if [ "${target_os}" == "win" ]
  then
    (
      export CFLAGS="-pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${EXPAT_FOLDER}/configure" --help
      bash "${work_folder_path}/${EXPAT_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --build="$(uname -m)-linux-gnu" \
        --host="${cross_compile_prefix}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
  then
    (
      export CFLAGS="-m${target_bits} -pipe -ffunction-sections -fdata-sections" 
      export CPPFLAGS="-I${install_folder}/include" 
      export LDFLAGS="-L${install_folder}/lib" 
      
      bash "${work_folder_path}/${EXPAT_FOLDER}/configure" --help
      bash "${work_folder_path}/${EXPAT_FOLDER}/configure" \
        --prefix="${install_folder}" \
        \
        --disable-shared \
        --enable-static \
      | tee "configure-output.txt"
    )
  fi

  echo
  echo "Running expat make..."

  # Build.
  # make clean
  make ${jobs}
  make install-strip

  touch "${expat_stamp_file}"
fi

# -------------------------------------------------------------

mkdir -p "${app_prefix}"
mkdir -p "${app_prefix_nano}"

# ----- Build BINUTILS. -----

binutils_folder="binutils-gdb"
binutils_stamp_file="${build_folder_path}/${binutils_folder}/stamp-install-completed"

if [ ! -f "${binutils_stamp_file}" ]
then

  mkdir -p "${build_folder_path}/${binutils_folder}"

  echo
  echo "Running binutils configure..."

  cd "${build_folder_path}/${binutils_folder}"

  if [ ! -f "config.status" ]
  then

    if [ "${target_os}" == "win" ]
    then
      (
        export CFLAGS="-Wno-unknown-warning-option -Wno-extended-offsetof -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-implicit-function-declaration -Wno-parentheses -Wno-format-nonliteral -Wno-shift-count-overflow -Wno-constant-logical-operand -Wno-shift-negative-value -Wno-format -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-format-nonliteral -Wno-format-security -Wno-deprecated -Wno-unknown-warning-option -Wno-c++11-narrowing -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/gdb/configure" --help
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}" \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --build="$(uname -m)-linux-gnu" \
          --host="${cross_compile_prefix}" \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --disable-shared \
          --enable-static \
          --disable-werror \
          --disable-build-warnings \
          --disable-gdb-build-warnings \
          --disable-nls \
          --enable-plugins \
          --without-system-zlib \
          --without-python \
          --with-expat \
          --with-sysroot="${app_prefix}/${gcc_target}" \
        | tee "configure-output.txt"
      )
    elif [ "${target_os}" == "osx" ]
    then
      (
        export CFLAGS="-Wno-unknown-warning-option -Wno-extended-offsetof -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-implicit-function-declaration -Wno-parentheses -Wno-format-nonliteral -Wno-shift-count-overflow -Wno-constant-logical-operand -Wno-shift-negative-value -Wno-format -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-format-nonliteral -Wno-format-security -Wno-deprecated -Wno-unknown-warning-option -Wno-c++11-narrowing -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -static-libstdc++" 
        
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/gdb/configure" --help
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}" \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --disable-shared \
          --enable-static \
          --disable-werror \
          --disable-build-warnings \
          --disable-gdb-build-warnings \
          --disable-nls \
          --enable-plugins \
          --without-system-zlib \
          --without-python \
          --with-expat \
          --with-sysroot="${app_prefix}/${gcc_target}" \
        | tee "configure-output.txt"
      )
    elif [ "${target_os}" == "linux" ]
    then
      (
        export CFLAGS="-Wno-unknown-warning-option -Wno-extended-offsetof -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-implicit-function-declaration -Wno-parentheses -Wno-format-nonliteral -Wno-shift-count-overflow -Wno-constant-logical-operand -Wno-shift-negative-value -Wno-format -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-format-nonliteral -Wno-format-security -Wno-deprecated -Wno-unknown-warning-option -Wno-c++11-narrowing -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/gdb/configure" --help
        bash "${work_folder_path}/${BINUTILS_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}" \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --disable-shared \
          --enable-static \
          --disable-werror \
          --disable-build-warnings \
          --disable-gdb-build-warnings \
          --disable-nls \
          --enable-plugins \
          --without-system-zlib \
          --without-python \
          --with-expat \
          --with-sysroot="${app_prefix}/${gcc_target}" \
        | tee "configure-output.txt"
      )
    fi
  fi

  echo
  echo "Running binutils make..."
  
  (
    # make clean
    make ${jobs} 
    make install
    if [ -z "${do_no_pdf}" ]
    then
      make ${jobs} html pdf
      make install-html install-pdf
    fi

    # Without this copy, the build for the nano version of the GCC second 
    # step fails with unexpected errors, like "cannot compute suffix of 
    # object files: cannot compile".
    do_copy_dir "${app_prefix}" "${app_prefix_nano}"
  ) | tee "make-newlib-all-output.txt"

  # The binutils were successfuly created.
  touch "${binutils_stamp_file}"
fi

# ----- Build GCC, first stage. -----

# The first stage creates a compiler without libraries, that is required
# to compile newlib. 
# For the Windows target this step is more or less useless, since 
# the build uses the GNU/Linux binaries (possible future optimisation).

gcc_folder="gcc"
gcc_stage1_folder="gcc-first"
gcc_stage1_stamp_file="${build_folder_path}/${gcc_stage1_folder}/stamp-install-completed"
# mkdir -p "${build_folder_path}/${gcc_stage1_folder}"

if [ ! -f "${gcc_stage1_stamp_file}" ]
then

  if [ -n "${GCC_MULTILIB}" ]
  then
    echo
    echo "Running the multilib generator..."

    cd "${work_folder_path}/${GCC_FOLDER_NAME}/gcc/config/riscv"
    # Be sure the ${GCC_MULTILIB} has no quotes, since it defines multiple strings.
    ./multilib-generator ${GCC_MULTILIB[@]} >"${GCC_MULTILIB_FILE}"
    cat "${GCC_MULTILIB_FILE}"
  fi

  mkdir -p "${build_folder_path}/${gcc_stage1_folder}"
  cd "${build_folder_path}/${gcc_stage1_folder}"

  if [ ! -f "config.status" ]
  then 

    echo
    echo "Running gcc first stage configure..."

    # https://gcc.gnu.org/install/configure.html
    # --enable-shared[=package[,…]] build shared versions of libraries
    # --enable-tls specify that the target supports TLS (Thread Local Storage). 
    # --enable-nls enables Native Language Support (NLS)
    # --enable-checking=list the compiler is built to perform internal consistency checks of the requested complexity. ‘yes’ (most common checks)
    # --with-headers=dir specify that target headers are available when building a cross compiler
    # --with-newlib Specifies that ‘newlib’ is being used as the target C library. This causes `__eprintf`` to be omitted from `libgcc.a`` on the assumption that it will be provided by newlib.
    # --enable-languages=c newlib does not use C++, so C should be enough
    
    if [ "${target_os}" == "win" ]
    then
      (
        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof -Wno-implicit-fallthrough -Wno-implicit-function-declaration -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-array-bounds -Wno-invalid-offsetof -Wno-implicit-fallthrough -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target}" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target}" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --build="$(uname -m)-linux-gnu" \
          --host="${cross_compile_prefix}" \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --disable-shared \
          --disable-threads \
          --disable-tls \
          --enable-languages=c \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-nls \
          --enable-checking=no \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --without-headers \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
    then
      (
        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof -Wno-implicit-fallthrough -Wno-implicit-function-declaration -Wno-mismatched-tags -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-keyword-macro -Wno-unused-private-field -Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-gnu-zero-variadic-macro-arguments -Wno-mismatched-tags -Wno-c99-extensions -Wno-array-bounds -Wno-extended-offsetof -Wno-invalid-offsetof -Wno-implicit-fallthrough  -Wno-mismatched-tags -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target}" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target}" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --disable-shared \
          --disable-threads \
          --disable-tls \
          --enable-languages=c \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-nls \
          --enable-checking=no \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --without-headers \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    fi
  fi

  # ----- Partial build, without documentation. -----
  echo
  echo "Running gcc first stage make..."

  cd "${build_folder_path}/${gcc_stage1_folder}"

  (
    # No need to make 'all', 'all-gcc' is enough to compile the libraries.
    # Parallel build fails for win32.
    make all-gcc
    make install-gcc
  ) | tee "make-all-output.txt"

  touch "${gcc_stage1_stamp_file}"
fi

# ----- Save PATH and set it to include the new binaries -----

saved_path=${PATH}
PATH="${app_prefix}/bin":${PATH}

# ----- Build newlib. -----

newlib_folder="newlib"
newlib_stamp_file="${build_folder_path}/${newlib_folder}/stamp-install-completed"
# mkdir -p "${build_folder_path}/${newlib_folder}"

if [ ! -f "${newlib_stamp_file}" ]
then

  mkdir -p "${build_folder_path}/${newlib_folder}"
  cd "${build_folder_path}/${newlib_folder}"

  if [ ! -f "config.status" ]
  then 

    # --enable-newlib-io-long-double   enable long double type support in IO functions printf/scanf
    # --enable-newlib-io-long-long   enable long long type support in IO functions like printf/scanf
    # --enable-newlib-io-c99-formats   enable C99 support in IO functions like printf/scanf
    # --enable-newlib-register-fini   enable finalization function registration using atexit
    # --disable-newlib-supplied-syscalls disable newlib from supplying syscalls
    # --disable-nls do not use Native Language Support

    # --enable-newlib-retargetable-locking ???
 
    echo
    echo "Running newlib configure..."

    if [ "${target_os}" == "win" ]
    then
      (
        export CFLAGS="-pipe" 
        export CXXFLAGS="-pipe" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections -Wno-implicit-function-declaration" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections" 
        
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --build="$(uname -m)-linux-gnu" \
          --host="${cross_compile_prefix}" \
          --target="${gcc_target}" \
          \
          --enable-newlib-io-long-double \
          --enable-newlib-io-long-long \
          --enable-newlib-io-c99-formats \
          --enable-newlib-register-fini \
          --disable-newlib-supplied-syscalls \
          --disable-nls \
          | tee "configure-output.txt"
      )
    elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
    then
      (
        export CFLAGS="-m${target_bits} -pipe" 
        export CXXFLAGS="-m${target_bits} -pipe" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections -Wno-implicit-function-declaration" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections" 
        
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --enable-newlib-io-long-double \
          --enable-newlib-io-long-long \
          --enable-newlib-io-c99-formats \
          --enable-newlib-register-fini \
          --disable-newlib-supplied-syscalls \
          --disable-nls \
          | tee "configure-output.txt"
      )
    fi
  fi

  echo
  echo "Running newlib make..."
  cd "${build_folder_path}/${newlib_folder}"
  (
    # make clean
    make ${jobs}  
    make install 

    if [ -z "${do_no_pdf}" ]
    then

      # Do not use parallel build here, it fails on Debian 32-bits.
      make pdf

      /usr/bin/install -v -c -m 644 \
        "${gcc_target}/libgloss/doc/porting.pdf" "${app_prefix_doc}/pdf"
      /usr/bin/install -v -c -m 644 \
        "${gcc_target}/newlib/libc/libc.pdf" "${app_prefix_doc}/pdf"
      /usr/bin/install -v -c -m 644 \
        "${gcc_target}/newlib/libm/libm.pdf" "${app_prefix_doc}/pdf"

      # Fails on Debian
      # make html
      # TODO: install html to "${app_prefix_doc}/html"
    
    fi

  ) | tee "make-newlib-all-output.txt"

  touch "${newlib_stamp_file}"
fi

# ----- Build newlib-nano. -----

newlib_nano_folder="newlib-nano"
newlib_nano_stamp_file="${build_folder_path}/${newlib_nano_folder}/stamp-install-completed"
# mkdir -p "${build_folder_path}/${newlib_nano_folder}"

if [ ! -f "${newlib_nano_stamp_file}" ]
then

  mkdir -p "${build_folder_path}/${newlib_nano_folder}"
  cd "${build_folder_path}/${newlib_nano_folder}"

  if [ ! -f "config.status" ]
  then 

    # --disable-newlib-supplied-syscalls disable newlib from supplying syscalls (__NO_SYSCALLS__)
    # --disable-newlib-fvwrite-in-streamio    disable iov in streamio
    # --disable-newlib-fseek-optimization    disable fseek optimization
    # --disable-newlib-wide-orient    Turn off wide orientation in streamio
    # --disable-newlib-unbuf-stream-opt    disable unbuffered stream optimization in streamio
    # --disable-nls do not use Native Language Support
    # --enable-newlib-io-long-double   enable long double type support in IO functions printf/scanf
    # --enable-newlib-io-long-long   enable long long type support in IO functions like printf/scanf
    # --enable-newlib-io-c99-formats   enable C99 support in IO functions like printf/scanf
    # --enable-newlib-register-fini   enable finalization function registration using atexit
    # --enable-newlib-nano-malloc    use small-footprint nano-malloc implementation
    # --enable-lite-exit	enable light weight exit
    # --enable-newlib-global-atexit	enable atexit data structure as global
    # --enable-newlib-nano-formatted-io    Use nano version formatted IO
    # --enable-newlib-reent-small

    # --enable-newlib-retargetable-locking ???

    echo
    echo "Running newlib-nano configure..."

    if [ "${target_os}" == "win" ]
    then
      (
        export CFLAGS="-Wno-implicit-function-declaration -pipe" 
        export CXXFLAGS="-pipe" 
        export CFLAGS_FOR_TARGET="-Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-logical-op-parentheses ${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" \
          --prefix="${app_prefix_nano}"  \
          --infodir="${app_prefix_nano_doc}/info" \
          --mandir="${app_prefix_nano_doc}/man" \
          --htmldir="${app_prefix_nano_doc}/html" \
          --pdfdir="${app_prefix_nano_doc}/pdf" \
          \
          --build="$(uname -m)-linux-gnu" \
          --host="${cross_compile_prefix}" \
          --target="${gcc_target}" \
          \
          --disable-newlib-supplied-syscalls \
          --disable-newlib-fvwrite-in-streamio \
          --disable-newlib-fseek-optimization \
          --disable-newlib-wide-orient \
          --disable-newlib-unbuf-stream-opt \
          --disable-nls \
          --enable-newlib-io-long-double \
          --enable-newlib-io-long-long \
          --enable-newlib-io-c99-formats \
          --enable-newlib-register-fini \
          --enable-newlib-nano-malloc \
          --enable-lite-exit \
          --enable-newlib-global-atexit \
          --enable-newlib-nano-formatted-io \
          --enable-newlib-reent-small \
          | tee "configure-output.txt"
      )
    elif [ \( "${target_os}" == "osx" \) -o \( "${target_os}" == "linux" \) ]
    then
      (
        export CFLAGS="-m${target_bits} -pipe" 
        export CXXFLAGS="-m${target_bits} -pipe" 
        export CFLAGS_FOR_TARGET="-Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-logical-op-parentheses ${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${NEWLIB_FOLDER_NAME}/configure" \
          --prefix="${app_prefix_nano}"  \
          --infodir="${app_prefix_nano_doc}/info" \
          --mandir="${app_prefix_nano_doc}/man" \
          --htmldir="${app_prefix_nano_doc}/html" \
          --pdfdir="${app_prefix_nano_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --disable-newlib-supplied-syscalls \
          --disable-newlib-fvwrite-in-streamio \
          --disable-newlib-fseek-optimization \
          --disable-newlib-wide-orient \
          --disable-newlib-unbuf-stream-opt \
          --disable-nls \
          --enable-newlib-io-long-double \
          --enable-newlib-io-long-long \
          --enable-newlib-io-c99-formats \
          --enable-newlib-register-fini \
          --enable-newlib-nano-malloc \
          --enable-lite-exit \
          --enable-newlib-global-atexit \
          --enable-newlib-nano-formatted-io \
          --enable-newlib-reent-small \
          | tee "configure-output.txt"
      )
    fi
  fi

  echo
  echo "Running newlib-nano make..."
  cd "${build_folder_path}/${newlib_nano_folder}"
  (
    # make clean
    make ${jobs}  
    make install 
  ) | tee "make-newlib-all-output.txt"

  touch "${newlib_nano_stamp_file}"
fi

# -------------------------------------------------------------

# Restore PATH
PATH="${saved_path}"

# -------------------------------------------------------------

gcc_stage2_folder="gcc-final"
gcc_stage2_stamp_file="${build_folder_path}/${gcc_stage2_folder}/stamp-install-completed"
# mkdir -p "${build_folder_path}/${gcc_stage2_folder}"

if [ ! -f "${gcc_stage2_stamp_file}" ]
then

  mkdir -p "${build_folder_path}/${gcc_stage2_folder}"
  cd "${build_folder_path}/${gcc_stage2_folder}"

  if [ ! -f "config.status" ]
  then

    # https://gcc.gnu.org/install/configure.html
    echo
    echo "Running gcc final stage configure..."

    if [ "${target_os}" == "win" ]
    then
      (
        # --without-system-zlib assume libz is not available

        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof -Wno-format-security -Wno-unused-but-set-variable -Wno-implicit-function-declaration -Wno-suggest-attribute -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-array-bounds -Wno-invalid-offsetof -Wno-format -Wno-format-extra-args -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections -Wno-mismatched-tags -Wno-ignored-attributes" 
        export LDFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -Wl,--gc-sections -static-libstdc++" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --build="$(uname -m)-linux-gnu" \
          --host="${cross_compile_prefix}" \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --enable-languages=c,c++ \
          --enable-plugins \
          --enable-tls \
          --enable-checking=yes \
          --disable-shared \
          --disable-threads \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-nls \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --with-headers="yes" \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    elif [ "${target_os}" == "osx" ]
    then
      (
        # no -ffunction-sections -fdata-sections / -Wl,--gc-sections for 
        # Apple default gcc (clang based)

        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof -Wno-char-subscripts -Wno-format-security -Wno-unused-but-set-variable -Wno-implicit-function-declaration -Wno-suggest-attribute -m${target_bits} -pipe" 
        export CXXFLAGS="-Wno-keyword-macro -Wno-unused-private-field -Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-gnu-zero-variadic-macro-arguments -Wno-mismatched-tags -Wno-c99-extensions -Wno-array-bounds -Wno-extended-offsetof -Wno-invalid-offsetof -Wno-format -Wno-format-extra-args -m${target_bits} -pipe" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections -Wno-mismatched-tags -Wno-ignored-attributes" 
        export LDFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -Wl,--gc-sections" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --enable-languages=c,c++ \
          --enable-plugins \
          --enable-tls \
          --enable-checking=yes \
          --disable-shared \
          --disable-threads \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-nls \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --with-headers="yes" \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    elif [ "${target_os}" == "linux" ]
    then
      (
        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof -Wno-format-security -Wno-unused-but-set-variable -Wno-implicit-function-declaration -Wno-suggest-attribute -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-keyword-macro -Wno-unused-private-field -Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-gnu-zero-variadic-macro-arguments -Wno-mismatched-tags -Wno-c99-extensions -Wno-array-bounds -Wno-extended-offsetof -Wno-invalid-offsetof -Wno-format -Wno-format-extra-args -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -ffunction-sections -fdata-sections -Wno-mismatched-tags -Wno-ignored-attributes"
        export LDFLAGS_FOR_TARGET="${cflags_optimizations_for_target} -Wl,--gc-sections" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix}"  \
          --infodir="${app_prefix_doc}/info" \
          --mandir="${app_prefix_doc}/man" \
          --htmldir="${app_prefix_doc}/html" \
          --pdfdir="${app_prefix_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --enable-languages=c,c++ \
          --enable-plugins \
          --enable-tls \
          --enable-checking=yes \
          --disable-shared \
          --disable-threads \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-nls \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --with-headers="yes" \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    fi
  fi

  # ----- Full build, with documentation. -----
  echo
  echo "Running gcc final stage make..."

  cd "${build_folder_path}/${gcc_stage2_folder}"

  (
    make ${jobs} 
    make install-strip
    if [ -z "${do_no_pdf}" ]
    then
      make install-pdf install-html
    fi
  ) | tee "make-all-output.txt"

  touch "${gcc_stage2_stamp_file}"
fi

# -------------------------------------------------------------

gcc_stage2_nano_folder="gcc-final-nano"
gcc_stage2_nano_stamp_file="${build_folder_path}/${gcc_stage2_nano_folder}/stamp-install-completed"
# mkdir -p "${build_folder_path}/${gcc_stage2_folder}"

if [ ! -f "${gcc_stage2_nano_stamp_file}" ]
then

  mkdir -p "${build_folder_path}/${gcc_stage2_nano_folder}"
  cd "${build_folder_path}/${gcc_stage2_nano_folder}"

  if [ ! -f "config.status" ]
  then

    # https://gcc.gnu.org/install/configure.html
    echo
    echo "Running gcc final stage nano configure..."

    if [ "${target_os}" == "win" ]
    then
      (
        # --without-system-zlib assume libz is not available

        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof  -Wno-format-security -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-array-bounds -Wno-invalid-offsetof -Wno-format -Wno-format-extra-args -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        export LDFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -Wl,--gc-sections" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix_nano}"  \
          --infodir="${app_prefix_nano_doc}/info" \
          --mandir="${app_prefix_nano_doc}/man" \
          --htmldir="${app_prefix_nano_doc}/html" \
          --pdfdir="${app_prefix_nano_doc}/pdf" \
          \
          --build="$(uname -m)-linux-gnu" \
          --host="${cross_compile_prefix}" \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --enable-languages=c,c++ \
          --enable-plugins \
          --enable-tls \
          --enable-checking=yes \
          --disable-shared \
          --disable-threads \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-libstdcxx-verbose \
          --disable-nls \
          ${multilib_flags} \
          --with-newlib \
          --without-system-zlib \
          --with-headers="yes" \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix_nano}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    elif [ "${target_os}" == "osx" ]
    then
      (
        # No -ffunction-sections -fdata-sections / -Wl,--gc-sections since  
        # for Apple the default gcc is clang based.
        # --disable-libstdcxx-verbose \

        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof  -Wno-char-subscripts -Wno-format-security -m${target_bits} -pipe" 
        export CXXFLAGS="-Wno-keyword-macro -Wno-unused-private-field -Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-gnu-zero-variadic-macro-arguments -Wno-mismatched-tags -Wno-c99-extensions -Wno-array-bounds -Wno-extended-offsetof -Wno-invalid-offsetof  -Wno-mismatched-tags -Wno-ignored-attributes -Wno-format -Wno-format-extra-args -m${target_bits} -pipe" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections -Wno-mismatched-tags -Wno-ignored-attributes" 
        export LDFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -Wl,--gc-sections" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix_nano}"  \
          --infodir="${app_prefix_nano_doc}/info" \
          --mandir="${app_prefix_nano_doc}/man" \
          --htmldir="${app_prefix_nano_doc}/html" \
          --pdfdir="${app_prefix_nano_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --enable-languages=c,c++ \
          --enable-plugins \
          --enable-tls \
          --enable-checking=yes \
          --disable-shared \
          --disable-threads \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-libstdcxx-verbose \
          --disable-nls \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --with-headers="yes" \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix_nano}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    elif [ "${target_os}" == "linux" ]
    then
      (
        export CFLAGS="-Wno-tautological-compare -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-value -Wno-extended-offsetof -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CXXFLAGS="-Wno-keyword-macro -Wno-unused-private-field -Wno-format-security -Wno-char-subscripts -Wno-deprecated -Wno-gnu-zero-variadic-macro-arguments -Wno-mismatched-tags -Wno-c99-extensions -Wno-array-bounds -Wno-extended-offsetof -Wno-invalid-offsetof  -Wno-format-security -Wno-format -Wno-format-extra-args -m${target_bits} -pipe -ffunction-sections -fdata-sections" 
        export CPPFLAGS="-I${install_folder}/include" 
        export LDFLAGS="-L${install_folder}/lib -Wl,--gc-sections -static-libstdc++" 
        export CFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections" 
        export CXXFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -ffunction-sections -fdata-sections -Wno-mismatched-tags -Wno-ignored-attributes" 
        export LDFLAGS_FOR_TARGET="${cflags_optimizations_nano_for_target} -Wl,--gc-sections" 
        
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" --help
        bash "${work_folder_path}/${GCC_FOLDER_NAME}/configure" \
          --prefix="${app_prefix_nano}"  \
          --infodir="${app_prefix_nano_doc}/info" \
          --mandir="${app_prefix_nano_doc}/man" \
          --htmldir="${app_prefix_nano_doc}/html" \
          --pdfdir="${app_prefix_nano_doc}/pdf" \
          \
          --target="${gcc_target}" \
          \
          --with-pkgversion="${branding}" \
          \
          --with-mpc="${install_folder}" \
          --with-mpfr="${install_folder}" \
          --with-gmp="${install_folder}" \
          --with-isl="${install_folder}" \
          \
          --enable-languages=c,c++ \
          --enable-plugins \
          --enable-tls \
          --enable-checking=yes \
          --disable-shared \
          --disable-threads \
          --disable-decimal-float \
          --disable-libffi \
          --disable-libgomp \
          --disable-libmudflap \
          --disable-libquadmath \
          --disable-libssp \
          --disable-libstdcxx-pch \
          --disable-libstdcxx-verbose \
          --disable-nls \
          ${multilib_flags} \
          --without-system-zlib \
          --with-newlib \
          --with-headers="yes" \
          --with-gnu-as \
          --with-gnu-ld \
          --with-abi="${gcc_abi}" \
          --with-arch="${gcc_arch}" \
          --with-sysroot="${app_prefix_nano}/${gcc_target}" \
          | tee "configure-output.txt"
      )
    fi
  fi

  # ----- Partial build -----
  echo
  echo "Running gcc final stage nano make..."

  cd "${build_folder_path}/${gcc_stage2_nano_folder}"

  (
    make ${jobs}
    make install-strip

    if [ "${target_os}" == "win" ]
    then
      host_gcc="${gcc_target}-gcc"
    else
      host_gcc="${app_prefix_nano}/bin/${gcc_target}-gcc"
    fi

    # Copy the libraries after appending the `_nano` suffix.
    # Iterate through all multilib names.
    do_copy_multi_libs \
      "${app_prefix_nano}/${gcc_target}/lib" \
      "${app_prefix}/${gcc_target}/lib" \
      "${host_gcc}"

    # Copy the nano configured newlib.h file into the location that nano.specs
    # expects it to be.
    mkdir -p "${app_prefix}/${gcc_target}/include/newlib-nano"
    cp -v -f "${app_prefix_nano}/${gcc_target}/include/newlib.h" \
      "${app_prefix}/${gcc_target}/include/newlib-nano/newlib.h"

  ) | tee "make-all-output.txt"

  touch "${gcc_stage2_nano_stamp_file}"
fi

# ----- Copy dynamic libraries to the install bin folder. -----

checking_stamp_file="${build_folder_path}/stamp_check_completed"

if [ ! -f "${checking_stamp_file}" ]
then

  if [ "${target_os}" == "win" ]
  then

    if [ -z "${do_no_strip}" ]
    then
      echo
      echo "Striping executables..."
      
      (
        cd "${app_prefix}"
        find "bin" "libexec/gcc/${gcc_target}" "${gcc_target}/bin" \
          -type f -executable -name '*.exe' \
          -exec ${cross_compile_prefix}-strip "{}" \;
      )

    fi

    echo
    echo "Copying DLLs..."

    # Identify the current cross gcc version, to locate the specific dll folder.
    CROSS_GCC_VERSION=$(${cross_compile_prefix}-gcc --version | grep 'gcc' | sed -e 's/.*\s\([0-9]*\)[.]\([0-9]*\)[.]\([0-9]*\).*/\1.\2.\3/')
    CROSS_GCC_VERSION_SHORT=$(echo $CROSS_GCC_VERSION | sed -e 's/\([0-9]*\)[.]\([0-9]*\)[.]\([0-9]*\).*/\1.\2/')
    SUBLOCATION="-win32"

    echo "${CROSS_GCC_VERSION}" "${CROSS_GCC_VERSION_SHORT}" "${SUBLOCATION}"

    if [ "${target_bits}" == "32" ]
    then
      do_container_win_copy_gcc_dll "libgcc_s_sjlj-1.dll"
    elif [ "${target_bits}" == "64" ]
    then
      do_container_win_copy_gcc_dll "libgcc_s_seh-1.dll"
    fi

    # do_container_win_copy_libwinpthread_dll

    if [ -z "${do_no_strip}" ]
    then
      echo
      echo "Striping DLLs..."

      ${cross_compile_prefix}-strip --strip-debug "${app_prefix}/bin/"*.dll
    fi

    (
      cd "${app_prefix}/bin"
      for f in *
      do
        if [ -x "${f}" ]
        then
          do_container_win_check_libs "${f}"
        fi
      done
    )

  elif [ "${target_os}" == "linux" ]
  then

    if [ -z "${do_no_strip}" ]
    then
      echo
      echo "Striping executables..."

      (
        cd "${app_prefix}"
        find "bin" "libexec/gcc/${gcc_target}" "${gcc_target}/bin" \
          -type f -executable \
          -exec strip "{}" \;
      )

    fi

    # Generally this is a very important detail: 'patchelf' sets "runpath"
    # in the ELF file to $ORIGIN, telling the loader to search
    # for the libraries first in LD_LIBRARY_PATH (if set) and, if not found there,
    # to look in the same folder where the executable is located -- where
    # this build script installs the required libraries. 
    # Note: LD_LIBRARY_PATH can be set by a developer when testing alternate 
    # versions of the openocd libraries without removing or overwriting 
    # the installed library files -- not done by the typical user. 
    # Note: patchelf changes the original "rpath" in the executable (a path 
    # in the docker container) to "runpath" with the value "$ORIGIN". rpath 
    # instead or runpath could be set to $ORIGIN but rpath is searched before
    # LD_LIBRARY_PATH which requires an installed library be deleted or
    # overwritten to test or use an alternate version. In addition, the usage of
    # rpath is deprecated. See man ld.so for more info.  
    # Also, runpath is added to the installed library files using patchelf, with 
    # value $ORIGIN, in the same way. See patchelf usage in build-helper.sh.
    #
    # In particular for GCC there should be no shared libraries.

    find "${app_prefix}/bin" -type f -executable \
        -exec patchelf --debug --set-rpath '$ORIGIN' "{}" \;

    (
      cd "${app_prefix}/bin"
      for f in *
      do
        if [ -x "${f}" ]
        then
          do_container_linux_check_libs "${f}"
        fi
      done
    )

  elif [ "${target_os}" == "osx" ]
  then

    if [ -z "${do_no_strip}" ]
    then
      echo
      echo "Striping executables..."

      strip "${app_prefix}/bin"/*

      strip "${app_prefix}/libexec/gcc/${gcc_target}"/*/cc1
      strip "${app_prefix}/libexec/gcc/${gcc_target}"/*/cc1plus
      strip "${app_prefix}/libexec/gcc/${gcc_target}"/*/collect2
      strip "${app_prefix}/libexec/gcc/${gcc_target}"/*/lto-wrapper
      strip "${app_prefix}/libexec/gcc/${gcc_target}"/*/lto1

      strip "${app_prefix}/${gcc_target}/bin"/*
    fi

    (
      cd "${app_prefix}/bin"
      for f in *
      do
        if [ -x "${f}" ]
        then
          do_container_mac_check_libs "${f}"
        fi
      done
    )

  fi

  touch "${checking_stamp_file}"
fi

# ----- Copy the license files. -----

license_stamp_file="${build_folder_path}/stamp_license_completed"

if [ ! -f "${license_stamp_file}" ]
then

  echo
  echo "Copying license files..."

  do_container_copy_license \
    "${work_folder_path}/${BINUTILS_FOLDER_NAME}" "${binutils_folder}"
  do_container_copy_license \
    "${work_folder_path}/${GCC_FOLDER_NAME}" "${gcc_folder}"
  do_container_copy_license \
    "${work_folder_path}/${NEWLIB_FOLDER_NAME}" "${newlib_folder}"

  do_container_copy_license \
    "${work_folder_path}/${GMP_FOLDER}" "${GMP_FOLDER}"
  do_container_copy_license \
    "${work_folder_path}/${MPFR_FOLDER}" "${MPFR_FOLDER}"
  do_container_copy_license \
    "${work_folder_path}/${MPC_FOLDER}" "${MPC_FOLDER}"
  do_container_copy_license \
    "${work_folder_path}/${ISL_FOLDER}" "${ISL_FOLDER}"

  if [ "${target_os}" == "win" ]
  then
    # Copy the LICENSE to be used by nsis.
    /usr/bin/install -v -c -m 644 "${git_folder_path}/LICENSE" "${install_folder}/${APP_LC_NAME}/licenses"

    find "${app_prefix}/licenses" -type f \
      -exec unix2dos {} \;
  fi

  touch "${license_stamp_file}"
fi

# ----- Copy the GNU MCU Eclipse info files. -----

info_stamp_file="${build_folder_path}/stamp_info_completed"

if [ ! -f "${info_stamp_file}" ]
then

  do_container_copy_info

  /usr/bin/install -cv -m 644 \
    "${build_folder_path}/${binutils_folder}/configure-output.txt" \
    "${app_prefix}/gnu-mcu-eclipse/binutils-configure-output.txt"
  do_unix2dos "${app_prefix}/gnu-mcu-eclipse/binutils-configure-output.txt"

  /usr/bin/install -cv -m 644 \
    "${build_folder_path}/${newlib_folder}/configure-output.txt" \
    "${app_prefix}/gnu-mcu-eclipse/newlib-configure-output.txt"
  do_unix2dos "${app_prefix}/gnu-mcu-eclipse/newlib-configure-output.txt"

  /usr/bin/install -cv -m 644 \
    "${build_folder_path}/${gcc_stage2_folder}/configure-output.txt" \
    "${app_prefix}/gnu-mcu-eclipse/gcc-configure-output.txt"
  do_unix2dos "${app_prefix}/gnu-mcu-eclipse/gcc-configure-output.txt"

  touch "${info_stamp_file}"
fi

# ----- Create the distribution package. -----

do_container_create_distribution

do_check_application "${gcc_target}-gdb" --version
do_check_application "${gcc_target}-g++" --version

do_container_copy_install

# Requires ${distribution_file} and ${result}
do_container_completed

stop_stamp_file="${install_folder}/stamp_completed"
touch "${stop_stamp_file}"

exit 0

__EOF__
# The above marker must start in the first column.

# ^===========================================================================^

# ----- Build the native distribution. -----

if [ -z "${DO_BUILD_OSX}${DO_BUILD_LINUX64}${DO_BUILD_WIN64}${DO_BUILD_LINUX32}${DO_BUILD_WIN32}" ]
then

  do_host_build_target "Creating the native distribution..." 

else

  # ----- Build the OS X distribution. -----

  if [ "${DO_BUILD_OSX}" == "y" ]
  then
    if [ "${HOST_UNAME}" == "Darwin" ]
    then
      do_host_build_target "Creating the OS X distribution..." \
        --target-os osx
    else
      echo "Building the macOS image is not possible on this platform."
      exit 1
    fi
  fi

  # ----- Build the GNU/Linux 64-bits distribution. -----

  docker_linux64_image="ilegeul/centos:6-xbb-v2"
  docker_linux32_image="ilegeul/centos32:6-xbb-v2"
  linux_distribution="centos"
  
  if [ "${DO_BUILD_LINUX64}" == "y" ]
  then
    do_host_build_target "Creating the GNU/Linux 64-bits distribution..." \
      --target-os linux \
      --target-bits 64 \
      --docker-image "${docker_linux64_image}"
  fi

  # ----- Build the Windows 64-bits distribution. -----

  if [ "${DO_BUILD_WIN64}" == "y" ]
  then
    if [ ! -f "${WORK_FOLDER_PATH}/install/${linux_distribution}64/${APP_LC_NAME}/bin/${gcc_target}-gcc" ]
    then
      do_host_build_target "Creating the GNU/Linux 64-bits distribution..." \
        --target-os linux \
        --target-bits 64 \
        --docker-image "${docker_linux64_image}"
    fi

    if [ ! -f "${WORK_FOLDER_PATH}/install/${linux_distribution}64/${APP_LC_NAME}/bin/${gcc_target}-gcc" ]
    then
      echo "Mandatory GNU/Linux binaries missing."
      exit 1
    fi

    do_host_build_target "Creating the Windows 64-bits distribution..." \
      --target-os win \
      --target-bits 64 \
      --docker-image "${docker_linux64_image}" \
      --build-binaries-path "install/${linux_distribution}64/${APP_LC_NAME}/bin"
  fi

  # ----- Build the GNU/Linux 32-bits distribution. -----

  if [ "${DO_BUILD_LINUX32}" == "y" ]
  then
    do_host_build_target "Creating the GNU/Linux 32-bits distribution..." \
      --target-os linux \
      --target-bits 32 \
      --docker-image "${docker_linux32_image}"
  fi

  # ----- Build the Windows 32-bits distribution. -----

  # Since the actual container is a 32-bits, use the debian32 binaries.
  if [ "${DO_BUILD_WIN32}" == "y" ]
  then
    if [ ! -f "${WORK_FOLDER_PATH}/install/${linux_distribution}32/${APP_LC_NAME}/bin/${gcc_target}-gcc" ]
    then
      do_host_build_target "Creating the GNU/Linux 32-bits distribution..." \
        --target-os linux \
        --target-bits 32 \
        --docker-image "${docker_linux32_image}"
    fi

    if [ ! -f "${WORK_FOLDER_PATH}/install/${linux_distribution}32/${APP_LC_NAME}/bin/${gcc_target}-gcc" ]
    then
      echo "Mandatory GNU/Linux binaries missing."
      exit 1
    fi

    do_host_build_target "Creating the Windows 32-bits distribution..." \
      --target-os win \
      --target-bits 32 \
      --docker-image "${docker_linux32_image}" \
      --build-binaries-path "install/${linux_distribution}32/${APP_LC_NAME}/bin"
  fi

fi

do_host_show_sha

do_host_stop_timer

# ----- Done. -----
exit 0
