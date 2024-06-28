#!/usr/bin/env bash
#
# Coverity scan script
#
# Copyright: SPDX-License-Identifier: GPL-3.0-or-later
#
# Author  : Costa Tsaousis (costa@netdata.cloud)
# Author  : Pawel Krupa (paulfantom)
# Author  : Pavlos Emm. Katsoulakis (paul@netdata.cloud)
# shellcheck disable=SC1091,SC2230,SC2086

# To run manually, save configuration to .coverity-scan.conf like this:
#
# the repository to report to coverity - devs can set here their own fork
# REPOSITORY="netdata/netdata"
#
# the email of the developer, as given to coverity
# COVERITY_SCAN_SUBMIT_MAIL="you@example.com"
#
# the token given by coverity to the developer
# COVERITY_SCAN_TOKEN="TOKEN taken from Coverity site"
#
# the absolute path of the cov-build - optional
# COVERITY_BUILD_PATH="/opt/cov-analysis-linux64-2021.12/bin/cov-build"
#
# when set, the script will print on screen the curl command that submits the build to coverity
# this includes the token, so the default is not to print it.
# COVERITY_SUBMIT_DEBUG=1
#
# Override the standard coverity build version we know is supported
# COVERITY_BUILD_VERSION="cov-analysis-linux64-2019.03"
#
# All these variables can also be exported before running this script.
#
# If the first parameter of this script is "install",
# coverity build tools will be downloaded and installed in /opt/coverity

set -e

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "This script can only be used on a 64-bit x86 Linux system."
  exit 1
fi

INSTALL_DIR="/opt"

SCRIPT_SOURCE="$(
    self=${0}
    while [ -L "${self}" ]
    do
        cd "${self%/*}" || exit 1
        self=$(readlink "${self}")
    done
    cd "${self%/*}" || exit 1
    echo "$(pwd -P)/${self##*/}"
)"
REPO_ROOT="$(dirname "${SCRIPT_SOURCE}")/../.."

. "${REPO_ROOT}/packaging/installer/functions.sh"

JOBS=$(find_processors)
[ -z "${JOBS}" ] && JOBS=1

if command -v ninja 2>&1; then
    ninja="$(command -v ninja)"
fi

CMAKE_OPTS="${ninja:+-G Ninja}"
BUILD_OPTS="VERBOSE=1"
[ -n "${ninja}" ] && BUILD_OPTS="-v"
NETDATA_BUILD_DIR="${NETDATA_BUILD_DIR:-./build/}"

if [ -f ".coverity-scan.conf" ]; then
  source ".coverity-scan.conf"
fi

repo="${REPOSITORY}"
if [ -z "${repo}" ]; then
  fatal "export variable REPOSITORY or set it in .coverity-scan.conf"
fi
repo="${repo//\//%2F}"

email="${COVERITY_SCAN_SUBMIT_MAIL}"
if [ -z "${email}" ]; then
  fatal "export variable COVERITY_SCAN_SUBMIT_MAIL or set it in .coverity-scan.conf"
fi

token="${COVERITY_SCAN_TOKEN}"
if [ -z "${token}" ]; then
  fatal "export variable COVERITY_SCAN_TOKEN or set it in .coverity-scan.conf"
fi

if ! command -v curl > /dev/null 2>&1; then
  fatal "CURL is required for coverity scan to work"
fi

# only print the output of a command
# when debugging is enabled
# used to hide the token when debugging is not enabled
debugrun() {
  if [ "${COVERITY_SUBMIT_DEBUG}" = "1" ]; then
    run "${@}"
    return $?
  else
    "${@}"
    return $?
  fi
}

scanit() {
  progress "Scanning using coverity"
  COVERITY_PATH=$(find "${INSTALL_DIR}" -maxdepth 1 -name 'cov*linux*')
  export PATH=${PATH}:${COVERITY_PATH}/bin/
  covbuild="${COVERITY_BUILD_PATH}"
  [ -z "${covbuild}" ] && covbuild="$(which cov-build 2> /dev/null || command -v cov-build 2> /dev/null)"

  if [ -z "${covbuild}" ]; then
    fatal "Cannot find 'cov-build' binary in \$PATH. Export variable COVERITY_BUILD_PATH or set it in .coverity-scan.conf"
  elif [ ! -x "${covbuild}" ]; then
    fatal "The command '${covbuild}' is not executable. Export variable COVERITY_BUILD_PATH or set it in .coverity-scan.conf"
  fi

  cd "${REPO_ROOT}" || exit 1

  version="$(grep "^#define PACKAGE_VERSION" config.h | cut -d '"' -f 2)"
  progress "Working on netdata version: ${version}"

  progress "Cleaning up old builds..."
  rm -rf "${NETDATA_BUILD_DIR}"

  [ -d "cov-int" ] && rm -rf "cov-int"

  [ -f netdata-coverity-analysis.tgz ] && run rm netdata-coverity-analysis.tgz

  progress "Configuring netdata source..."
  USE_SYSTEM_PROTOBUF=1
  ENABLE_GO=0
  prepare_cmake_options

  run cmake ${NETDATA_CMAKE_OPTIONS}

  progress "Analyzing netdata..."
  run "${covbuild}" --dir cov-int cmake --build "${NETDATA_BUILD_DIR}" --parallel ${JOBS} -- ${BUILD_OPTS}

  echo >&2 "Compressing analysis..."
  run tar czvf netdata-coverity-analysis.tgz cov-int

  echo >&2 "Sending analysis to coverity for netdata version ${version} ..."
  COVERITY_SUBMIT_RESULT=$(debugrun curl --progress-bar \
    --form token="${token}" \
    --form email="${email}" \
    --form file=@netdata-coverity-analysis.tgz \
    --form version="${version}" \
    --form description="netdata, monitor everything, in real-time." \
    https://scan.coverity.com/builds?project="${repo}")

  echo "${COVERITY_SUBMIT_RESULT}" | grep -q -e 'Build successfully submitted' || echo >&2 "scan results were not pushed to coverity. Message was: ${COVERITY_SUBMIT_RESULT}"

  progress "Coverity scan completed"
}

installit() {
  ORIGINAL_DIR="${PWD}"
  TMP_DIR="$(mktemp -d /tmp/netdata-coverity-scan-XXXXX)"
  progress "Downloading coverity in ${TMP_DIR}..."
  cd "${TMP_DIR}"

  debugrun curl --remote-name --remote-header-name --show-error --location --data "token=${token}&project=${repo}" https://scan.coverity.com/download/linux64

  if [ -z "${COVERITY_BUILD_VERSION}" ]; then
    COVERITY_ARCHIVE="$(find  "${TMP_DIR}" -maxdepth 0 -name 'cov-analysis-linux64-*.tar.gz' | cut -f 2 -d '/' | head -n 1)"
  else
    COVERITY_ARCHIVE="${TMP_DIR}/${COVERITY_BUILD_VERSION}.tar.gz"
  fi

  if [ -f "${COVERITY_ARCHIVE}" ]; then
    progress "Installing coverity..."
    cd "${INSTALL_DIR}"

    run sudo tar -z -x -f "${COVERITY_ARCHIVE}" || exit 1
    rm -f "${COVERITY_ARCHIVE}"
    COVERITY_PATH=$(find "${INSTALL_DIR}" -maxdepth 1 -name 'cov*linux*')
    export PATH=${PATH}:${COVERITY_PATH}/bin/
  elif find . -name "*.tar.gz" > /dev/null 2>&1; then
    ls ./*.tar.gz
    fatal "Downloaded coverity tool tarball does not appear to be the version we were expecting, exiting."
  else
    fatal "Failed to download coverity tool tarball!"
  fi

  # Validate the installation
  covbuild="$(which cov-build 2> /dev/null || command -v cov-build 2> /dev/null)"
  if [ -z "$covbuild" ]; then
    fatal "Failed to install coverity."
  fi

  progress "Coverity scan tools are installed."
  cd "$ORIGINAL_DIR"

  # Clean temp directory
  [ -n "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
  return 0
}

FOUND_OPTS="NO"
while [ -n "${1}" ]; do
  if [ "${1}" = "--with-install" ]; then
    progress "Running coverity install"
    installit
    shift 1
  elif [ -n "${1}" ]; then
    # Clear the default arguments, once you bump into the first argument
    if [ "${FOUND_OPTS}" = "NO" ]; then
      OTHER_OPTIONS="${1}"
      FOUND_OPTS="YES"
    else
      OTHER_OPTIONS+=" ${1}"
    fi

    shift 1
  else
    break
  fi
done

echo "Running coverity scan with extra options ${OTHER_OPTIONS}"
scanit "${OTHER_OPTIONS}"
