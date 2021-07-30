#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2046,SC2086,SC2166

export PATH="${PATH}:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
uniquepath() {
  local path=""
  while read -r; do
    if [[ ! ${path} =~ (^|:)"${REPLY}"(:|$) ]]; then
      [ -n "${path}" ] && path="${path}:"
      path="${path}${REPLY}"
    fi
  done < <(echo "${PATH}" | tr ":" "\n")

  [ -n "${path}" ] && [[ ${PATH} =~ /bin ]] && [[ ${PATH} =~ /sbin ]] && export PATH="${path}"
}
uniquepath

PROGRAM="$0"
NETDATA_SOURCE_DIR="$(pwd)"
INSTALLER_DIR="$(dirname "${PROGRAM}")"

if [ "${NETDATA_SOURCE_DIR}" != "${INSTALLER_DIR}" ] && [ "${INSTALLER_DIR}" != "." ]; then
  echo >&2 "Warning: you are currently in '${NETDATA_SOURCE_DIR}' but the installer is in '${INSTALLER_DIR}'."
fi

# -----------------------------------------------------------------------------
# Pull in OpenSSL properly if on macOS
if [ "$(uname -s)" = 'Darwin' ] && [ -d /usr/local/opt/openssl/include ]; then
  export C_INCLUDE_PATH="/usr/local/opt/openssl/include"
  export LDFLAGS="-L/usr/local/opt/openssl@1.1/lib"
fi

# -----------------------------------------------------------------------------
# reload the user profile

# shellcheck source=/dev/null
[ -f /etc/profile ] && . /etc/profile

# make sure /etc/profile does not change our current directory
cd "${NETDATA_SOURCE_DIR}" || exit 1

# -----------------------------------------------------------------------------
# figure out an appropriate temporary directory
_cannot_use_tmpdir() {
  local testfile ret
  testfile="$(TMPDIR="${1}" mktemp -q -t netdata-test.XXXXXXXXXX)"
  ret=0

  if [ -z "${testfile}" ]; then
    return "${ret}"
  fi

  if printf '#!/bin/sh\necho SUCCESS\n' > "${testfile}"; then
    if chmod +x "${testfile}"; then
      if [ "$("${testfile}")" = "SUCCESS" ]; then
        ret=1
      fi
    fi
  fi

  rm -f "${testfile}"
  return "${ret}"
}

if [ -z "${TMPDIR}" ] || _cannot_use_tmpdir "${TMPDIR}"; then
  if _cannot_use_tmpdir /tmp; then
    if _cannot_use_tmpdir "${PWD}"; then
      echo >&2
      echo >&2 "Unable to find a usable temporary directory. Please set \$TMPDIR to a path that is both writable and allows execution of files and try again."
      exit 1
    else
      TMPDIR="${PWD}"
    fi
  else
    TMPDIR="/tmp"
  fi
fi

# -----------------------------------------------------------------------------
# set up handling for deferred error messages
NETDATA_DEFERRED_ERRORS=""

defer_error() {
  NETDATA_DEFERRED_ERRORS="${NETDATA_DEFERRED_ERRORS}\n* ${1}"
}

defer_error_highlighted() {
  NETDATA_DEFERRED_ERRORS="${TPUT_YELLOW}${TPUT_BOLD}${NETDATA_DEFERRED_ERRORS}\n* ${1}${TPUT_RESET}"
}

print_deferred_errors() {
  if [ -n "${NETDATA_DEFERRED_ERRORS}" ]; then
    echo >&2
    echo >&2 "The following non-fatal errors were encountered during the installation process:"
    # shellcheck disable=SC2059
    printf >&2 "${NETDATA_DEFERRED_ERRORS}"
    echo >&2
  fi
}

# -----------------------------------------------------------------------------
# load the required functions

if [ -f "${INSTALLER_DIR}/packaging/installer/functions.sh" ]; then
  # shellcheck source=packaging/installer/functions.sh
  source "${INSTALLER_DIR}/packaging/installer/functions.sh" || exit 1
else
  # shellcheck source=packaging/installer/functions.sh
  source "${NETDATA_SOURCE_DIR}/packaging/installer/functions.sh" || exit 1
fi

download_go() {
  download_file "${1}" "${2}" "go.d plugin" "go"
}

# make sure we save all commands we run
run_logfile="netdata-installer.log"

# -----------------------------------------------------------------------------
# fix PKG_CHECK_MODULES error

if [ -d /usr/share/aclocal ]; then
  ACLOCAL_PATH=${ACLOCAL_PATH-/usr/share/aclocal}
  export ACLOCAL_PATH
fi

export LC_ALL=C
umask 002

# Be nice on production environments
renice 19 $$ > /dev/null 2> /dev/null

# you can set CFLAGS before running installer
LDFLAGS="${LDFLAGS}"
CFLAGS="${CFLAGS--O2}"
[ "z${CFLAGS}" = "z-O3" ] && CFLAGS="-O2"
ACLK="${ACLK}"

# keep a log of this command
# shellcheck disable=SC2129
printf "\n# " >> netdata-installer.log
date >> netdata-installer.log
printf 'CFLAGS="%s" ' "${CFLAGS}" >> netdata-installer.log
printf 'LDFLAGS="%s" ' "${LDFLAGS}" >> netdata-installer.log
printf "%q " "${PROGRAM}" "${@}" >> netdata-installer.log
printf "\n" >> netdata-installer.log

REINSTALL_OPTIONS="$(
  printf "%s" "${*}"
  printf "\n"
)"
# remove options that shown not be inherited by netdata-updater.sh
REINSTALL_OPTIONS="$(echo "${REINSTALL_OPTIONS}" | sed 's/--dont-wait//g' | sed 's/--dont-start-it//g')"

banner_nonroot_install() {
  cat << NONROOTNOPREFIX

  ${TPUT_RED}${TPUT_BOLD}Sorry! This will fail!${TPUT_RESET}

  You are attempting to install netdata as non-root, but you plan
  to install it in system paths.

  Please set an installation prefix, like this:

      $PROGRAM ${@} --install /tmp

  or, run the installer as root:

      sudo $PROGRAM ${@}

  We suggest to install it as root, or certain data collectors will
  not be able to work. Netdata drops root privileges when running.
  So, if you plan to keep it, install it as root to get the full
  functionality.

NONROOTNOPREFIX
}

banner_root_notify() {
  cat << NONROOT

  ${TPUT_RED}${TPUT_BOLD}IMPORTANT${TPUT_RESET}:
  You are about to install netdata as a non-root user.
  Netdata will work, but a few data collection modules that
  require root access will fail.

  If you installing netdata permanently on your system, run
  the installer like this:

     ${TPUT_YELLOW}${TPUT_BOLD}sudo $PROGRAM ${@}${TPUT_RESET}

NONROOT
}

usage() {
  netdata_banner "installer command line options"
  cat << HEREDOC

USAGE: ${PROGRAM} [options]
       where options include:

  --install <path>           Install netdata in <path>. Ex. --install /opt will put netdata in /opt/netdata
  --dont-start-it            Do not (re)start netdata after installation
  --dont-wait                Run installation in non-interactive mode
  --auto-update or -u        Install netdata-updater in cron to update netdata automatically once per day
  --auto-update-type         Override the auto-update scheduling mechanism detection, currently supported types
                             are: systemd, interval, crontab
  --stable-channel           Use packages from GitHub release pages instead of GCS (nightly updates).
                             This results in less frequent updates.
  --nightly-channel          Use most recent nightly updates instead of GitHub releases.
                             This results in more frequent updates.
  --disable-go               Disable installation of go.d.plugin.
  --disable-ebpf             Disable eBPF Kernel plugin (Default: enabled)
  --disable-cloud            Disable all Netdata Cloud functionality.
  --require-cloud            Fail the install if it can't build Netdata Cloud support.
  --aclk-legacy              Forces build of ACLK Legacy which is fallback by default.
  --enable-plugin-freeipmi   Enable the FreeIPMI plugin. Default: enable it when libipmimonitoring is available.
  --disable-plugin-freeipmi
  --disable-https            Explicitly disable TLS support
  --disable-dbengine         Explicitly disable DB engine support
  --enable-plugin-nfacct     Enable nfacct plugin. Default: enable it when libmnl and libnetfilter_acct are available.
  --disable-plugin-nfacct
  --enable-plugin-xenstat    Enable the xenstat plugin. Default: enable it when libxenstat and libyajl are available
  --disable-plugin-xenstat   Disable the xenstat plugin.
  --enable-backend-kinesis   Enable AWS Kinesis backend. Default: enable it when libaws_cpp_sdk_kinesis and libraries
                             it depends on are available.
  --disable-backend-kinesis
  --enable-backend-prometheus-remote-write Enable Prometheus remote write backend. Default: enable it when libprotobuf and
                             libsnappy are available.
  --disable-backend-prometheus-remote-write
  --enable-backend-mongodb   Enable MongoDB backend. Default: enable it when libmongoc is available.
  --disable-backend-mongodb
  --enable-lto               Enable Link-Time-Optimization. Default: enabled
  --disable-lto
  --disable-x86-sse          Disable SSE instructions. By default SSE optimizations are enabled.
  --use-system-lws           Use a system copy of libwebsockets instead of bundling our own (default is to use the bundled copy).
  --zlib-is-really-here or
  --libs-are-really-here     If you get errors about missing zlib or libuuid but you know it is available, you might
                             have a broken pkg-config. Use this option to proceed without checking pkg-config.
  --disable-telemetry        Use this flag to opt-out from our anonymous telemetry program. (DO_NOT_TRACK=1)

Netdata will by default be compiled with gcc optimization -O2
If you need to pass different CFLAGS, use something like this:

  CFLAGS="<gcc options>" ${PROGRAM} [options]

If you also need to provide different LDFLAGS, use something like this:

  LDFLAGS="<extra ldflag options>" ${PROGRAM} [options]

or use the following if both LDFLAGS and CFLAGS need to be overridden:

  CFLAGS="<gcc options>" LDFLAGS="<extra ld options>" ${PROGRAM} [options]

For the installer to complete successfully, you will need these packages installed:

  gcc make autoconf automake pkg-config zlib1g-dev (or zlib-devel) uuid-dev (or libuuid-devel)

For the plugins, you will at least need:

  curl, bash v4+, python v2 or v3, node.js

HEREDOC
}

DONOTSTART=0
DONOTWAIT=0
AUTOUPDATE=0
NETDATA_PREFIX=
LIBS_ARE_HERE=0
NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS-}"
RELEASE_CHANNEL="nightly" # check .travis/create_artifacts.sh before modifying
IS_NETDATA_STATIC_BINARY="${IS_NETDATA_STATIC_BINARY:-"no"}"
while [ -n "${1}" ]; do
  case "${1}" in
    "--zlib-is-really-here") LIBS_ARE_HERE=1 ;;
    "--libs-are-really-here") LIBS_ARE_HERE=1 ;;
    "--use-system-lws") USE_SYSTEM_LWS=1 ;;
    "--dont-scrub-cflags-even-though-it-may-break-things") DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS=1 ;;
    "--dont-start-it") DONOTSTART=1 ;;
    "--dont-wait") DONOTWAIT=1 ;;
    "--auto-update" | "-u") AUTOUPDATE=1 ;;
    "--auto-update-type")
      AUTO_UPDATE_TYPE="$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
      case "${AUTO_UPDATE_TYPE}" in
        systemd|interval|crontab)
          shift 1
          ;;
        *)
          echo "Unrecognized value for --auto-update-type. Valid values are: systemd, interval, crontab"
          exit 1
          ;;
      esac
      ;;
    "--stable-channel") RELEASE_CHANNEL="stable" ;;
    "--nightly-channel") RELEASE_CHANNEL="nightly" ;;
    "--enable-plugin-freeipmi") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-plugin-freeipmi/} --enable-plugin-freeipmi" ;;
    "--disable-plugin-freeipmi") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-plugin-freeipmi/} --disable-plugin-freeipmi" ;;
    "--disable-https") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-https/} --disable-https" ;;
    "--disable-dbengine")
      NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-dbengine/} --disable-dbengine"
      NETDATA_DISABLE_DBENGINE=1
      ;;
    "--enable-plugin-nfacct") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-plugin-nfacct/} --enable-plugin-nfacct" ;;
    "--disable-plugin-nfacct") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-plugin-nfacct/} --disable-plugin-nfacct" ;;
    "--enable-plugin-xenstat") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-plugin-xenstat/} --enable-plugin-xenstat" ;;
    "--disable-plugin-xenstat") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-plugin-xenstat/} --disable-plugin-xenstat" ;;
    "--enable-backend-kinesis") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-backend-kinesis/} --enable-backend-kinesis" ;;
    "--disable-backend-kinesis") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-backend-kinesis/} --disable-backend-kinesis" ;;
    "--enable-backend-prometheus-remote-write") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-backend-prometheus-remote-write/} --enable-backend-prometheus-remote-write" ;;
    "--disable-backend-prometheus-remote-write") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-backend-prometheus-remote-write/} --disable-backend-prometheus-remote-write" ;;
    "--enable-backend-mongodb") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-backend-mongodb/} --enable-backend-mongodb" ;;
    "--disable-backend-mongodb") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-backend-mongodb/} --disable-backend-mongodb" ;;
    "--enable-lto") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-lto/} --enable-lto" ;;
    "--disable-lto") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-lto/} --disable-lto" ;;
    "--disable-x86-sse") NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-x86-sse/} --disable-x86-sse" ;;
    "--disable-telemetry") NETDATA_DISABLE_TELEMETRY=1 ;;
    "--disable-go") NETDATA_DISABLE_GO=1 ;;
    "--enable-ebpf") NETDATA_DISABLE_EBPF=0 ;;
    "--disable-ebpf") NETDATA_DISABLE_EBPF=1 NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-ebpf/} --disable-ebpf" ;;
    "--aclk-ng") ;;
    "--aclk-legacy")
      NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--with-aclk-legacy/} --with-aclk-legacy"
      ;;
    "--disable-cloud")
      if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
        echo "Cloud explicitly enabled, ignoring --disable-cloud."
      else
        NETDATA_DISABLE_CLOUD=1
        NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--disable-cloud/} --disable-cloud"
      fi
      ;;
    "--require-cloud")
      if [ -n "${NETDATA_DISABLE_CLOUD}" ]; then
        echo "Cloud explicitly disabled, ignoring --require-cloud."
      else
        NETDATA_REQUIRE_CLOUD=1
        NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//--enable-cloud/} --enable-cloud"
      fi
      ;;
    "--build-json-c")
      NETDATA_BUILD_JSON_C=1
      ;;
    "--build-judy")
      NETDATA_BUILD_JUDY=1
      ;;
    "--install")
      NETDATA_PREFIX="${2}/netdata"
      shift 1
      ;;
    "--help" | "-h")
      usage
      exit 1
      ;;
    *)
      run_failed "I cannot understand option '$1'."
      usage
      exit 1
      ;;
  esac
  shift 1
done

make="make"
# See: https://github.com/netdata/netdata/issues/9163
if [ "$(uname -s)" = "FreeBSD" ]; then
  make="gmake"
  NETDATA_CONFIGURE_OPTIONS="$NETDATA_CONFIGURE_OPTIONS --disable-dependency-tracking"
fi

# replace multiple spaces with a single space
NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS//  / }"

if [ "${UID}" -ne 0 ]; then
  if [ -z "${NETDATA_PREFIX}" ]; then
    netdata_banner "wrong command line options!"
    banner_nonroot_install "${@}"
    exit 1
  else
    banner_root_notify "${@}"
  fi
fi

netdata_banner "real-time performance monitoring, done right!"
cat << BANNER1

  You are about to build and install netdata to your system.

  The build process will use ${TPUT_CYAN}${TMPDIR}${TPUT_RESET} for
  any temporary files. You can override this by setting \$TMPDIR to a
  writable directory where you can execute files.

  It will be installed at these locations:

   - the daemon     at ${TPUT_CYAN}${NETDATA_PREFIX}/usr/sbin/netdata${TPUT_RESET}
   - config files   in ${TPUT_CYAN}${NETDATA_PREFIX}/etc/netdata${TPUT_RESET}
   - web files      in ${TPUT_CYAN}${NETDATA_PREFIX}/usr/share/netdata${TPUT_RESET}
   - plugins        in ${TPUT_CYAN}${NETDATA_PREFIX}/usr/libexec/netdata${TPUT_RESET}
   - cache files    in ${TPUT_CYAN}${NETDATA_PREFIX}/var/cache/netdata${TPUT_RESET}
   - db files       in ${TPUT_CYAN}${NETDATA_PREFIX}/var/lib/netdata${TPUT_RESET}
   - log files      in ${TPUT_CYAN}${NETDATA_PREFIX}/var/log/netdata${TPUT_RESET}
BANNER1

[ "${UID}" -eq 0 ] && cat << BANNER2
   - pid file       at ${TPUT_CYAN}${NETDATA_PREFIX}/var/run/netdata.pid${TPUT_RESET}
   - logrotate file at ${TPUT_CYAN}/etc/logrotate.d/netdata${TPUT_RESET}
BANNER2

cat << BANNER3

  This installer allows you to change the installation path.
  Press Control-C and run the same command with --help for help.

BANNER3

if [ -z "$NETDATA_DISABLE_TELEMETRY" ]; then
  cat << BANNER4

  ${TPUT_YELLOW}${TPUT_BOLD}NOTE${TPUT_RESET}:
  Anonymous usage stats will be collected and sent to Netdata.
  To opt-out, pass --disable-telemetry option to the installer or export
  the environment variable DO_NOT_TRACK to a non-zero or non-empty value
  (e.g: export DO_NOT_TRACK=1).

BANNER4
fi

have_autotools=
if [ "$(type autoreconf 2> /dev/null)" ]; then
  autoconf_maj_min() {
    local maj min IFS=.-

    maj=$1
    min=$2

    set -- $(autoreconf -V | sed -ne '1s/.* \([^ ]*\)$/\1/p')
    eval $maj=\$1 $min=\$2
  }
  autoconf_maj_min AMAJ AMIN

  if [ "$AMAJ" -gt 2 ]; then
    have_autotools=Y
  elif [ "$AMAJ" -eq 2 -a "$AMIN" -ge 60 ]; then
    have_autotools=Y
  else
    echo "Found autotools $AMAJ.$AMIN"
  fi
else
  echo "No autotools found"
fi

if [ ! "$have_autotools" ]; then
  if [ -f configure ]; then
    echo "Will skip autoreconf step"
  else
    netdata_banner "autotools v2.60 required"
    cat << "EOF"

-------------------------------------------------------------------------------
autotools 2.60 or later is required

Sorry, you do not seem to have autotools 2.60 or later, which is
required to build from the git sources of netdata.

EOF
    exit 1
  fi
fi

if [ ${DONOTWAIT} -eq 0 ]; then
  if [ -n "${NETDATA_PREFIX}" ]; then
    echo -n "${TPUT_BOLD}${TPUT_GREEN}Press ENTER to build and install netdata to '${TPUT_CYAN}${NETDATA_PREFIX}${TPUT_YELLOW}'${TPUT_RESET} > "
  else
    echo -n "${TPUT_BOLD}${TPUT_GREEN}Press ENTER to build and install netdata to your system${TPUT_RESET} > "
  fi
  read -ern1
  if [ "$REPLY" != '' ]; then
    exit 1
  fi

fi

build_error() {
  netdata_banner "sorry, it failed to build..."
  cat << EOF

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Sorry! netdata failed to build...

You may need to check these:

1. The package uuid-dev (or libuuid-devel) has to be installed.

   If your system cannot find libuuid, although it is installed
   run me with the option:  --libs-are-really-here

2. The package zlib1g-dev (or zlib-devel) has to be installed.

   If your system cannot find zlib, although it is installed
   run me with the option:  --libs-are-really-here

3. The package json-c-dev (or json-c-devel) has to be installed.

   If your system cannot find json-c, although it is installed
   run me with the option:  --libs-are-really-here

4. You need basic build tools installed, like:

   gcc make autoconf automake pkg-config

   Autoconf version 2.60 or higher is required.

If you still cannot get it to build, ask for help at github:

   https://github.com/netdata/netdata/issues


EOF
  trap - EXIT
  exit 1
}

if [ ${LIBS_ARE_HERE} -eq 1 ]; then
  shift
  echo >&2 "ok, assuming libs are really installed."
  export ZLIB_CFLAGS=" "
  export ZLIB_LIBS="-lz"
  export UUID_CFLAGS=" "
  export UUID_LIBS="-luuid"
fi

trap build_error EXIT

# -----------------------------------------------------------------------------

build_libmosquitto() {
  local env_cmd=''

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS=-fPIC CXXFLAGS= LDFLAGS="
  fi

  if [ "$(uname -s)" = Linux ]; then
    run ${env_cmd} ${make} -j$(find_processors) -C "${1}/lib"
  else
    pushd ${1} > /dev/null || return 1
    if [ "$(uname)" = "Darwin" ] && [ -d /usr/local/opt/openssl ]; then
      run ${env_cmd} cmake \
        -D OPENSSL_ROOT_DIR=/usr/local/opt/openssl \
        -D OPENSSL_LIBRARIES=/usr/local/opt/openssl/lib \
        -D WITH_STATIC_LIBRARIES:boolean=YES \
        .
    else
      run ${env_cmd} cmake -D WITH_STATIC_LIBRARIES:boolean=YES .
    fi
    run ${env_cmd} ${make} -j$(find_processors) -C lib
    run mv lib/libmosquitto_static.a lib/libmosquitto.a
    popd || return 1
  fi
}

copy_libmosquitto() {
  target_dir="${PWD}/externaldeps/mosquitto"

  run mkdir -p "${target_dir}"

  run cp "${1}/lib/libmosquitto.a" "${target_dir}"
  run cp "${1}/lib/mosquitto.h" "${target_dir}"
}

bundle_libmosquitto() {
  if [ -n "${NETDATA_DISABLE_CLOUD}" ]; then
    echo "Skipping libmosquitto"
    return 0
  fi

  progress "Prepare custom libmosquitto version"

  MOSQUITTO_PACKAGE_VERSION="$(cat packaging/mosquitto.version)"

  tmp="$(mktemp -d -t netdata-mosquitto-XXXXXX)"
  MOSQUITTO_PACKAGE_BASENAME="${MOSQUITTO_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "mosquitto" \
    "https://github.com/netdata/mosquitto/archive/${MOSQUITTO_PACKAGE_BASENAME}" \
    "${MOSQUITTO_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${NETDATA_LOCAL_TARBALL_OVERRIDE_MOSQUITTO}"; then
    if run tar -xf "${tmp}/${MOSQUITTO_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_libmosquitto "${tmp}/mosquitto-${MOSQUITTO_PACKAGE_VERSION}" &&
      copy_libmosquitto "${tmp}/mosquitto-${MOSQUITTO_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "libmosquitto built and prepared."
    else
      run_failed "Failed to build libmosquitto."
      if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
        exit 1
      else
        defer_error_highlighted "Unable to fetch sources for libmosquitto. You will not be able to connect this node to Netdata Cloud."
      fi
    fi
  else
    run_failed "Unable to fetch sources for libmosquitto."
    if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
      exit 1
    else
      defer_error_highlighted "Unable to fetch sources for libmosquitto. You will not be able to connect this node to Netdata Cloud."
    fi
  fi
}

bundle_libmosquitto

# -----------------------------------------------------------------------------

build_libwebsockets() {
  local env_cmd=''

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS=-fPIC CXXFLAGS= LDFLAGS="
  fi

  pushd "${1}" > /dev/null || exit 1

  if [ "$(uname)" = "Darwin" ]; then
    run patch -p1 << "EOF"
--- a/lib/plat/unix/private.h
+++ b/lib/plat/unix/private.h
@@ -164,6 +164,8 @@ delete_from_fd(const struct lws_context *context, int fd);
  * but happily have something equivalent in the SO_NOSIGPIPE flag.
  */
 #ifdef __APPLE__
+/* iOS SDK 12+ seems to define it, undef it for compatibility both ways */
+#undef MSG_NOSIGNAL
 #define MSG_NOSIGNAL SO_NOSIGPIPE
 #endif
EOF

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
      return 1
    fi
  fi

  if [ "$(uname)" = "Darwin" ] && [ -d /usr/local/opt/openssl ]; then
    run ${env_cmd} cmake \
      -D OPENSSL_ROOT_DIR=/usr/local/opt/openssl \
      -D OPENSSL_LIBRARIES=/usr/local/opt/openssl/lib \
      -D LWS_WITH_SOCKS5:bool=ON \
      -D LWS_IPV6:bool=ON \
      $CMAKE_FLAGS \
      .
  else
    run ${env_cmd} cmake \
      -D LWS_WITH_SOCKS5:bool=ON \
      -D LWS_IPV6:bool=ON \
      $CMAKE_FLAGS \
      .
  fi
  run ${env_cmd} ${make} -j$(find_processors)
  popd > /dev/null || exit 1
}

copy_libwebsockets() {
  target_dir="${PWD}/externaldeps/libwebsockets"

  run mkdir -p "${target_dir}" || return 1

  run cp "${1}/lib/libwebsockets.a" "${target_dir}/libwebsockets.a" || return 1
  run cp -r "${1}/include" "${target_dir}" || return 1
}

bundle_libwebsockets() {
  if [ -n "${NETDATA_DISABLE_CLOUD}" ] || [ -n "${USE_SYSTEM_LWS}" ]; then
    echo "Skipping libwebsockets"
    return 0
  fi

  if [ -z "$(command -v cmake)" ]; then
    run_failed "Could not find cmake, which is required to build libwebsockets. The install process will continue, but you may not be able to connect this node to Netdata Cloud."
    defer_error_highlighted "Could not find cmake, which is required to build libwebsockets. The install process will continue, but you may not be able to connect this node to Netdata Cloud."
    return 0
  fi

  progress "Prepare libwebsockets"

  LIBWEBSOCKETS_PACKAGE_VERSION="$(cat packaging/libwebsockets.version)"

  tmp="$(mktemp -d -t netdata-libwebsockets-XXXXXX)"
  LIBWEBSOCKETS_PACKAGE_BASENAME="v${LIBWEBSOCKETS_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "libwebsockets" \
    "https://github.com/warmcat/libwebsockets/archive/${LIBWEBSOCKETS_PACKAGE_BASENAME}" \
    "${LIBWEBSOCKETS_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${NETDATA_LOCAL_TARBALL_OVERRIDE_LIBWEBSOCKETS}"; then
    if run tar -xf "${tmp}/${LIBWEBSOCKETS_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_libwebsockets "${tmp}/libwebsockets-${LIBWEBSOCKETS_PACKAGE_VERSION}" &&
      copy_libwebsockets "${tmp}/libwebsockets-${LIBWEBSOCKETS_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "libwebsockets built and prepared."
      NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS} --with-bundled-lws"
    else
      run_failed "Failed to build libwebsockets."
      if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
        exit 1
      else
        defer_error_highlighted "Failed to build libwebsockets. You may not be able to connect this node to Netdata Cloud."
      fi
    fi
  else
    run_failed "Unable to fetch sources for libwebsockets."
    if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
      exit 1
    else
      defer_error_highlighted "Unable to fetch sources for libwebsockets. You may not be able to connect this node to Netdata Cloud."
    fi
  fi
}

bundle_libwebsockets

# -----------------------------------------------------------------------------

build_judy() {
  local env_cmd=''
  local libtoolize="libtoolize"

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS=-fPIC CXXFLAGS= LDFLAGS="
  fi

  if [ "$(uname)" = "Darwin" ]; then
    libtoolize="glibtoolize"
  fi

  pushd "${1}" > /dev/null || return 1
  if run ${env_cmd} ${libtoolize} --force --copy &&
    run ${env_cmd} aclocal &&
    run ${env_cmd} autoheader &&
    run ${env_cmd} automake --add-missing --force --copy --include-deps &&
    run ${env_cmd} autoconf &&
    run ${env_cmd} ./configure &&
    run ${env_cmd} ${make} -j$(find_processors) -C src &&
    run ${env_cmd} ar -r src/libJudy.a src/Judy*/*.o; then
    popd > /dev/null || return 1
  else
    popd > /dev/null || return 1
    return 1
  fi
}

copy_judy() {
  target_dir="${PWD}/externaldeps/libJudy"

  run mkdir -p "${target_dir}" || return 1

  run cp "${1}/src/libJudy.a" "${target_dir}/libJudy.a" || return 1
  run cp "${1}/src/Judy.h" "${target_dir}/Judy.h" || return 1
}

bundle_judy() {
  # If --build-judy flag or no Judy on the system and we're building the dbengine, bundle our own libJudy.
  # shellcheck disable=SC2235
  if [ -n "${NETDATA_DISABLE_DBENGINE}" ] || ([ -z "${NETDATA_BUILD_JUDY}" ] && [ -e /usr/include/Judy.h ]); then
    return 0
  elif [ -n "${NETDATA_BUILD_JUDY}" ]; then
    progress "User requested bundling of libJudy, building it now"
  elif [ ! -e /usr/include/Judy.h ]; then
    progress "/usr/include/Judy.h does not exist, but we need libJudy, building our own copy"
  fi

  progress "Prepare libJudy"

  JUDY_PACKAGE_VERSION="$(cat packaging/judy.version)"

  tmp="$(mktemp -d -t netdata-judy-XXXXXX)"
  JUDY_PACKAGE_BASENAME="v${JUDY_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "judy" \
    "https://github.com/netdata/libjudy/archive/${JUDY_PACKAGE_BASENAME}" \
    "${JUDY_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${NETDATA_LOCAL_TARBALL_OVERRIDE_JUDY}"; then
    if run tar -xf "${tmp}/${JUDY_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_judy "${tmp}/libjudy-${JUDY_PACKAGE_VERSION}" &&
      copy_judy "${tmp}/libjudy-${JUDY_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "libJudy built and prepared."
      NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS} --with-bundled-libJudy"
    else
      run_failed "Failed to build libJudy."
      if [ -n "${NETDATA_BUILD_JUDY}" ]; then
        exit 1
      else
        defer_error_highlighted "Failed to build libJudy. dbengine support will be disabled."
      fi
    fi
  else
    run_failed "Unable to fetch sources for libJudy."
    if [ -n "${NETDATA_BUILD_JUDY}" ]; then
      exit 1
    else
      defer_error_highlighted "Unable to fetch sources for libJudy. dbengine support will be disabled."
    fi
  fi
}

bundle_judy

# -----------------------------------------------------------------------------

build_jsonc() {
  local env_cmd=''

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS=-fPIC CXXFLAGS= LDFLAGS="
  fi

  pushd "${1}" > /dev/null || exit 1
  run ${env_cmd} cmake -DBUILD_SHARED_LIBS=OFF .
  run ${env_cmd} ${make} -j$(find_processors)
  popd > /dev/null || exit 1
}

copy_jsonc() {
  target_dir="${PWD}/externaldeps/jsonc"

  run mkdir -p "${target_dir}" "${target_dir}/json-c" || return 1

  run cp "${1}/libjson-c.a" "${target_dir}/libjson-c.a" || return 1
  run cp ${1}/*.h "${target_dir}/json-c" || return 1
}

bundle_jsonc() {
  # If --build-json-c flag or not json-c on system, then bundle our own json-c
  if [ -z "${NETDATA_BUILD_JSON_C}" ] && pkg-config json-c; then
    return 0
  fi

  if [ -z "$(command -v cmake)" ]; then
    run_failed "Could not find cmake, which is required to build JSON-C. The install process will continue, but Netdata Cloud support will be disabled."
    defer_error_highlighted "Could not find cmake, which is required to build JSON-C. The install process will continue, but Netdata Cloud support will be disabled."
    return 0
  fi

  progress "Prepare JSON-C"

  JSONC_PACKAGE_VERSION="$(cat packaging/jsonc.version)"

  tmp="$(mktemp -d -t netdata-jsonc-XXXXXX)"
  JSONC_PACKAGE_BASENAME="json-c-${JSONC_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "jsonc" \
    "https://github.com/json-c/json-c/archive/${JSONC_PACKAGE_BASENAME}" \
    "${JSONC_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${NETDATA_LOCAL_TARBALL_OVERRIDE_JSONC}"; then
    if run tar -xf "${tmp}/${JSONC_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_jsonc "${tmp}/json-c-json-c-${JSONC_PACKAGE_VERSION}" &&
      copy_jsonc "${tmp}/json-c-json-c-${JSONC_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "JSON-C built and prepared."
    else
      run_failed "Failed to build JSON-C."
      if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
        exit 1
      else
        defer_error_highlighted "Failed to build JSON-C. Netdata Cloud support will be disabled."
      fi
    fi
  else
    run_failed "Unable to fetch sources for JSON-C."
    if [ -n "${NETDATA_REQUIRE_CLOUD}" ]; then
      exit 1
    else
      defer_error_highlighted "Unable to fetch sources for JSON-C. Netdata Cloud support will be disabled."
    fi
  fi
}

bundle_jsonc

# -----------------------------------------------------------------------------

build_libbpf() {
  pushd "${1}/src" > /dev/null || exit 1
  run env CFLAGS=-fPIC CXXFLAGS= LDFLAGS= BUILD_STATIC_ONLY=y OBJDIR=build DESTDIR=.. ${make} -j$(find_processors) install
  popd > /dev/null || exit 1
}

copy_libbpf() {
  target_dir="${PWD}/externaldeps/libbpf"

  if [ "$(uname -m)" = x86_64 ]; then
    lib_subdir="lib64"
  else
    lib_subdir="lib"
  fi

  run mkdir -p "${target_dir}" || return 1

  run cp "${1}/usr/${lib_subdir}/libbpf.a" "${target_dir}/libbpf.a" || return 1
  run cp -r "${1}/usr/include" "${target_dir}" || return 1
}

bundle_libbpf() {
  if { [ -n "${NETDATA_DISABLE_EBPF}" ] && [ ${NETDATA_DISABLE_EBPF} = 1 ]; } || [ "$(uname -s)" != Linux ]; then
    return 0
  fi

  progress "Prepare libbpf"

  LIBBPF_PACKAGE_VERSION="$(cat packaging/libbpf.version)"

  tmp="$(mktemp -d -t netdata-libbpf-XXXXXX)"
  LIBBPF_PACKAGE_BASENAME="v${LIBBPF_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "libbpf" \
    "https://github.com/netdata/libbpf/archive/${LIBBPF_PACKAGE_BASENAME}" \
    "${LIBBPF_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${NETDATA_LOCAL_TARBALL_OVERRIDE_LIBBPF}"; then
    if run tar -xf "${tmp}/${LIBBPF_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_libbpf "${tmp}/libbpf-${LIBBPF_PACKAGE_VERSION}" &&
      copy_libbpf "${tmp}/libbpf-${LIBBPF_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "libbpf built and prepared."
    else
      run_failed "Failed to build libbpf."
      if [ -n "${NETDATA_DISABLE_EBPF}" ] && [ ${NETDATA_DISABLE_EBPF} = 0 ]; then
        exit 1
      else
        defer_error_highlighted "Failed to build libbpf. You may not be able to use eBPF plugin."
      fi
    fi
  else
    run_failed "Unable to fetch sources for libbpf."
    if [ -n "${NETDATA_DISABLE_EBPF}" ] && [ ${NETDATA_DISABLE_EBPF} = 0 ]; then
      exit 1
    else
      defer_error_highlighted "Unable to fetch sources for libbpf. You may not be able to use eBPF plugin."
    fi
  fi
}

bundle_libbpf

# -----------------------------------------------------------------------------
# If we have the dashboard switching logic, make sure we're on the classic
# dashboard during the install (updates don't work correctly otherwise).
if [ -x "${NETDATA_PREFIX}/usr/libexec/netdata-switch-dashboard.sh" ]; then
  "${NETDATA_PREFIX}/usr/libexec/netdata-switch-dashboard.sh" classic
fi

# -----------------------------------------------------------------------------
# By default, `git` does not update local tags based on remotes. Because
# we use the most recent tag as part of our version determination in
# our build, this can lead to strange versions that look ancient but are
# actually really recent. To avoid this, try and fetch tags if we're
# working in a git checkout.
if [ -d ./.git ] ; then
  echo >&2
  progress "Updating tags in git to ensure a consistent version number"
  run git fetch <remote> 'refs/tags/*:refs/tags/*' || true
fi

# -----------------------------------------------------------------------------
echo >&2
progress "Run autotools to configure the build environment"

if [ "$have_autotools" ]; then
  run autoreconf -ivf || exit 1
fi

run ./configure \
  --prefix="${NETDATA_PREFIX}/usr" \
  --sysconfdir="${NETDATA_PREFIX}/etc" \
  --localstatedir="${NETDATA_PREFIX}/var" \
  --libexecdir="${NETDATA_PREFIX}/usr/libexec" \
  --libdir="${NETDATA_PREFIX}/usr/lib" \
  --with-zlib \
  --with-math \
  --with-user=netdata \
  ${NETDATA_CONFIGURE_OPTIONS} \
  CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" || exit 1

# remove the build_error hook
trap - EXIT

# -----------------------------------------------------------------------------
progress "Cleanup compilation directory"

run $make clean

# -----------------------------------------------------------------------------
progress "Compile netdata"

run $make -j$(find_processors) || exit 1

# -----------------------------------------------------------------------------
progress "Migrate configuration files for node.d.plugin and charts.d.plugin"

# migrate existing configuration files
# for node.d and charts.d
if [ -d "${NETDATA_PREFIX}/etc/netdata" ]; then
  # the configuration directory exists

  if [ ! -d "${NETDATA_PREFIX}/etc/netdata/charts.d" ]; then
    run mkdir "${NETDATA_PREFIX}/etc/netdata/charts.d"
  fi

  # move the charts.d config files
  for x in apache ap cpu_apps cpufreq example exim hddtemp load_average mem_apps mysql nginx nut opensips phpfpm postfix sensors squid tomcat; do
    for y in "" ".old" ".orig"; do
      if [ -f "${NETDATA_PREFIX}/etc/netdata/${x}.conf${y}" -a ! -f "${NETDATA_PREFIX}/etc/netdata/charts.d/${x}.conf${y}" ]; then
        run mv -f "${NETDATA_PREFIX}/etc/netdata/${x}.conf${y}" "${NETDATA_PREFIX}/etc/netdata/charts.d/${x}.conf${y}"
      fi
    done
  done

  if [ ! -d "${NETDATA_PREFIX}/etc/netdata/node.d" ]; then
    run mkdir "${NETDATA_PREFIX}/etc/netdata/node.d"
  fi

  # move the node.d config files
  for x in named sma_webbox snmp; do
    for y in "" ".old" ".orig"; do
      if [ -f "${NETDATA_PREFIX}/etc/netdata/${x}.conf${y}" -a ! -f "${NETDATA_PREFIX}/etc/netdata/node.d/${x}.conf${y}" ]; then
        run mv -f "${NETDATA_PREFIX}/etc/netdata/${x}.conf${y}" "${NETDATA_PREFIX}/etc/netdata/node.d/${x}.conf${y}"
      fi
    done
  done
fi

# -----------------------------------------------------------------------------

# shellcheck disable=SC2230
md5sum="$(command -v md5sum 2> /dev/null || command -v md5 2> /dev/null)"

deleted_stock_configs=0
if [ ! -f "${NETDATA_PREFIX}/etc/netdata/.installer-cleanup-of-stock-configs-done" ]; then

  progress "Backup existing netdata configuration before installing it"

  if [ "${BASH_VERSINFO[0]}" -ge "4" ]; then
    declare -A configs_signatures=()
    if [ -f "configs.signatures" ]; then
      source "configs.signatures" || echo >&2 "ERROR: Failed to load configs.signatures !"
    fi
  fi

  config_signature_matches() {
    local md5="${1}" file="${2}"

    if [ "${BASH_VERSINFO[0]}" -ge "4" ]; then
      [ "${configs_signatures[${md5}]}" = "${file}" ] && return 0
      return 1
    fi

    if [ -f "configs.signatures" ]; then
      grep "\['${md5}'\]='${file}'" "configs.signatures" > /dev/null
      return $?
    fi

    return 1
  }

  # clean up stock config files from the user configuration directory
  while IFS= read -r -d '' x; do
    if [ -f "${x}" ]; then
      # find it relative filename
      f="${x/${NETDATA_PREFIX}\/etc\/netdata\//}"

      # find the stock filename
      t="${f/.conf.installer_backup.*/.conf}"
      t="${t/.conf.old/.conf}"
      t="${t/.conf.orig/.conf}"
      t="${t/orig\//}"

      if [ -z "${md5sum}" -o ! -x "${md5sum}" ]; then
        # we don't have md5sum - keep it
        echo >&2 "File '${TPUT_CYAN}${x}${TPUT_RESET}' ${TPUT_RED}is not known to distribution${TPUT_RESET}. Keeping it."
      else
        # find its checksum
        md5="$(${md5sum} < "${x}" | cut -d ' ' -f 1)"

        if config_signature_matches "${md5}" "${t}"; then
          # it is a stock version - remove it
          echo >&2 "File '${TPUT_CYAN}${x}${TPUT_RESET}' is stock version of '${t}'."
          run rm -f "${x}"
          deleted_stock_configs=$((deleted_stock_configs + 1))
        else
          # edited by user - keep it
          echo >&2 "File '${TPUT_CYAN}${x}${TPUT_RESET}' ${TPUT_RED} does not match stock of${TPUT_RESET} ${TPUT_CYAN}'${t}'${TPUT_RESET}. Keeping it."
        fi
      fi
    fi
  done < <(find -L "${NETDATA_PREFIX}/etc/netdata" -type f -not -path '*/\.*' -not -path "${NETDATA_PREFIX}/etc/netdata/orig/*" \( -name '*.conf.old' -o -name '*.conf' -o -name '*.conf.orig' -o -name '*.conf.installer_backup.*' \))
fi
touch "${NETDATA_PREFIX}/etc/netdata/.installer-cleanup-of-stock-configs-done"

# -----------------------------------------------------------------------------
progress "Install netdata"

run $make install || exit 1

# -----------------------------------------------------------------------------
progress "Fix generated files permissions"

run find ./system/ -type f -a \! -name \*.in -a \! -name Makefile\* -a \! -name \*.conf -a \! -name \*.service -a \! -name \*.timer -a \! -name \*.logrotate -a \! -name \.install-type -exec chmod 755 {} \;

# -----------------------------------------------------------------------------
progress "Creating standard user and groups for netdata"

NETDATA_WANTED_GROUPS="docker nginx varnish haproxy adm nsd proxy squid ceph nobody"
NETDATA_ADDED_TO_GROUPS=""
if [ "${UID}" -eq 0 ]; then
  progress "Adding group 'netdata'"
  portable_add_group netdata || :

  progress "Adding user 'netdata'"
  portable_add_user netdata "${NETDATA_PREFIX}/var/lib/netdata" || :

  progress "Assign user 'netdata' to required groups"
  for g in ${NETDATA_WANTED_GROUPS}; do
    # shellcheck disable=SC2086
    portable_add_user_to_group ${g} netdata && NETDATA_ADDED_TO_GROUPS="${NETDATA_ADDED_TO_GROUPS} ${g}"
  done
else
  run_failed "The installer does not run as root. Nothing to do for user and groups"
fi

# -----------------------------------------------------------------------------
progress "Install logrotate configuration for netdata"

install_netdata_logrotate

# -----------------------------------------------------------------------------
progress "Read installation options from netdata.conf"

# create an empty config if it does not exist
[ ! -f "${NETDATA_PREFIX}/etc/netdata/netdata.conf" ] &&
  touch "${NETDATA_PREFIX}/etc/netdata/netdata.conf"

# function to extract values from the config file
config_option() {
  local section="${1}" key="${2}" value="${3}"

  if [ -s "${NETDATA_PREFIX}/etc/netdata/netdata.conf" ]; then
    "${NETDATA_PREFIX}/usr/sbin/netdata" \
      -c "${NETDATA_PREFIX}/etc/netdata/netdata.conf" \
      -W get "${section}" "${key}" "${value}" ||
      echo "${value}"
  else
    echo "${value}"
  fi
}

# the user netdata will run as
if [ "${UID}" = "0" ]; then
  NETDATA_USER="$(config_option "global" "run as user" "netdata")"
  ROOT_USER="root"
else
  NETDATA_USER="${USER}"
  ROOT_USER="${USER}"
fi
NETDATA_GROUP="$(id -g -n "${NETDATA_USER}")"
[ -z "${NETDATA_GROUP}" ] && NETDATA_GROUP="${NETDATA_USER}"
echo >&2 "Netdata user and group is finally set to: ${NETDATA_USER}/${NETDATA_GROUP}"

# the owners of the web files
NETDATA_WEB_USER="$(config_option "web" "web files owner" "${NETDATA_USER}")"
NETDATA_WEB_GROUP="${NETDATA_GROUP}"
if [ "${UID}" = "0" ] && [ "${NETDATA_USER}" != "${NETDATA_WEB_USER}" ]; then
  NETDATA_WEB_GROUP="$(id -g -n "${NETDATA_WEB_USER}")"
  [ -z "${NETDATA_WEB_GROUP}" ] && NETDATA_WEB_GROUP="${NETDATA_WEB_USER}"
fi
NETDATA_WEB_GROUP="$(config_option "web" "web files group" "${NETDATA_WEB_GROUP}")"

# port
defport=19999
NETDATA_PORT="$(config_option "web" "default port" ${defport})"

# directories
NETDATA_LIB_DIR="$(config_option "global" "lib directory" "${NETDATA_PREFIX}/var/lib/netdata")"
NETDATA_CACHE_DIR="$(config_option "global" "cache directory" "${NETDATA_PREFIX}/var/cache/netdata")"
NETDATA_WEB_DIR="$(config_option "global" "web files directory" "${NETDATA_PREFIX}/usr/share/netdata/web")"
NETDATA_LOG_DIR="$(config_option "global" "log directory" "${NETDATA_PREFIX}/var/log/netdata")"
NETDATA_USER_CONFIG_DIR="$(config_option "global" "config directory" "${NETDATA_PREFIX}/etc/netdata")"
NETDATA_STOCK_CONFIG_DIR="$(config_option "global" "stock config directory" "${NETDATA_PREFIX}/usr/lib/netdata/conf.d")"
NETDATA_RUN_DIR="${NETDATA_PREFIX}/var/run"
NETDATA_CLAIMING_DIR="${NETDATA_LIB_DIR}/cloud.d"

cat << OPTIONSEOF

    Permissions
    - netdata user             : ${NETDATA_USER}
    - netdata group            : ${NETDATA_GROUP}
    - web files user           : ${NETDATA_WEB_USER}
    - web files group          : ${NETDATA_WEB_GROUP}
    - root user                : ${ROOT_USER}

    Directories
    - netdata user config dir  : ${NETDATA_USER_CONFIG_DIR}
    - netdata stock config dir : ${NETDATA_STOCK_CONFIG_DIR}
    - netdata log dir          : ${NETDATA_LOG_DIR}
    - netdata run dir          : ${NETDATA_RUN_DIR}
    - netdata lib dir          : ${NETDATA_LIB_DIR}
    - netdata web dir          : ${NETDATA_WEB_DIR}
    - netdata cache dir        : ${NETDATA_CACHE_DIR}

    Other
    - netdata port             : ${NETDATA_PORT}

OPTIONSEOF

# -----------------------------------------------------------------------------
progress "Fix permissions of netdata directories (using user '${NETDATA_USER}')"

if [ ! -d "${NETDATA_RUN_DIR}" ]; then
  # this is needed if NETDATA_PREFIX is not empty
  run mkdir -p "${NETDATA_RUN_DIR}" || exit 1
fi

# --- stock conf dir ----

[ ! -d "${NETDATA_STOCK_CONFIG_DIR}" ] && mkdir -p "${NETDATA_STOCK_CONFIG_DIR}"

helplink="000.-.USE.THE.orig.LINK.TO.COPY.AND.EDIT.STOCK.CONFIG.FILES"
[ ${deleted_stock_configs} -eq 0 ] && helplink=""
for link in "orig" "${helplink}"; do
  if [ -n "${link}" ]; then
    [ -L "${NETDATA_USER_CONFIG_DIR}/${link}" ] && run rm -f "${NETDATA_USER_CONFIG_DIR}/${link}"
    run ln -s "${NETDATA_STOCK_CONFIG_DIR}" "${NETDATA_USER_CONFIG_DIR}/${link}"
  fi
done

# --- web dir ----

if [ ! -d "${NETDATA_WEB_DIR}" ]; then
  echo >&2 "Creating directory '${NETDATA_WEB_DIR}'"
  run mkdir -p "${NETDATA_WEB_DIR}" || exit 1
fi
run chown -R "${NETDATA_WEB_USER}:${NETDATA_WEB_GROUP}" "${NETDATA_WEB_DIR}"
run find "${NETDATA_WEB_DIR}" -type f -exec chmod 0664 {} \;
run find "${NETDATA_WEB_DIR}" -type d -exec chmod 0775 {} \;

# --- data dirs ----

for x in "${NETDATA_LIB_DIR}" "${NETDATA_CACHE_DIR}" "${NETDATA_LOG_DIR}"; do
  if [ ! -d "${x}" ]; then
    echo >&2 "Creating directory '${x}'"
    run mkdir -p "${x}" || exit 1
  fi

  run chown -R "${NETDATA_USER}:${NETDATA_GROUP}" "${x}"
  #run find "${x}" -type f -exec chmod 0660 {} \;
  #run find "${x}" -type d -exec chmod 0770 {} \;
done

run chmod 755 "${NETDATA_LOG_DIR}"

# --- claiming dir ----

if [ ! -d "${NETDATA_CLAIMING_DIR}" ]; then
  echo >&2 "Creating directory '${NETDATA_CLAIMING_DIR}'"
  run mkdir -p "${NETDATA_CLAIMING_DIR}" || exit 1
fi
run chown -R "${NETDATA_USER}:${NETDATA_GROUP}" "${NETDATA_CLAIMING_DIR}"
run chmod 770 "${NETDATA_CLAIMING_DIR}"

# --- plugins ----

if [ "${UID}" -eq 0 ]; then
  # find the admin group
  admin_group=
  test -z "${admin_group}" && getent group root > /dev/null 2>&1 && admin_group="root"
  test -z "${admin_group}" && getent group daemon > /dev/null 2>&1 && admin_group="daemon"
  test -z "${admin_group}" && admin_group="${NETDATA_GROUP}"

  run chown "${NETDATA_USER}:${admin_group}" "${NETDATA_LOG_DIR}"
  run chown -R "root:${admin_group}" "${NETDATA_PREFIX}/usr/libexec/netdata"
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type d -exec chmod 0755 {} \;
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type f -exec chmod 0644 {} \;
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type f -a -name \*.plugin -exec chown :${NETDATA_GROUP} {} \;
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type f -a -name \*.plugin -exec chmod 0750 {} \;
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type f -a -name \*.sh -exec chmod 0755 {} \;

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin" ]; then
    run chown "root:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1> /dev/null 2>&1; then
      run chmod 0750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"
      if run setcap cap_dac_read_search,cap_sys_ptrace+ep "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"; then
        # if we managed to setcap, but we fail to execute apps.plugin setuid to root
        "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin" -t > /dev/null 2>&1 && capabilities=1 || capabilities=0
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      # fix apps.plugin to be setuid to root
      run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"
    fi
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/freeipmi.plugin" ]; then
    run chown "root:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/freeipmi.plugin"
    run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/freeipmi.plugin"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/nfacct.plugin" ]; then
    run chown "root:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/nfacct.plugin"
    run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/nfacct.plugin"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/xenstat.plugin" ]; then
    run chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/xenstat.plugin"
    run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/xenstat.plugin"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/perf.plugin" ]; then
    run chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/perf.plugin"
    run chmod 0750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/perf.plugin"
    run sh -c "setcap cap_perfmon+ep \"${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/perf.plugin\" || setcap cap_sys_admin+ep \"${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/perf.plugin\""
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/slabinfo.plugin" ]; then
    run chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/slabinfo.plugin"
    run chmod 0750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/slabinfo.plugin"
    run setcap cap_dac_read_search+ep "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/slabinfo.plugin"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ioping" ]; then
    run chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ioping"
    run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ioping"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ebpf.plugin" ]; then
    run chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ebpf.plugin"
    run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ebpf.plugin"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/cgroup-network" ]; then
    run chown "root:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/cgroup-network"
    run chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/cgroup-network"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/cgroup-network-helper.sh" ]; then
    run chown "root:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/cgroup-network-helper.sh"
    run chmod 0750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/cgroup-network-helper.sh"
  fi
else
  # non-privileged user installation
  run chown "${NETDATA_USER}:${NETDATA_GROUP}" "${NETDATA_LOG_DIR}"
  run chown -R "${NETDATA_USER}:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata"
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type f -exec chmod 0755 {} \;
  run find "${NETDATA_PREFIX}/usr/libexec/netdata" -type d -exec chmod 0755 {} \;
fi

# -----------------------------------------------------------------------------

# govercomp compares go.d.plugin versions. Exit codes:
# 0 - version1 == version2
# 1 - version1 > version2
# 2 - version2 > version1
# 3 - error
govercomp() {
  # version in file:
  # - v0.14.0
  #
  # 'go.d.plugin -v' output variants:
  # - go.d.plugin, version: unknown
  # - go.d.plugin, version: v0.14.1
  # - go.d.plugin, version: v0.14.1-dirty
  # - go.d.plugin, version: v0.14.1-1-g4c5f98c
  # - go.d.plugin, version: v0.14.1-1-g4c5f98c-dirty

  # we need to compare only MAJOR.MINOR.PATCH part
  local ver1 ver2
  ver1=$(echo "$1" | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
  ver2=$(echo "$2" | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")

  local IFS=.
  read -ra ver1 <<< "$ver1"
  read -ra ver2 <<< "$ver2"

  if [ ${#ver1[@]} -eq 0 ] || [ ${#ver2[@]} -eq 0 ]; then
    return 3
  fi

  local i
  for ((i = 0; i < ${#ver1[@]}; i++)); do
    if [ "${ver1[i]}" -gt "${ver2[i]}" ]; then
      return 1
    elif [ "${ver2[i]}" -gt "${ver1[i]}" ]; then
      return 2
    fi
  done

  return 0
}

should_install_go() {
  if [ -n "${NETDATA_DISABLE_GO+x}" ]; then
    return 1
  fi

  local version_in_file
  local binary_version

  version_in_file="$(cat packaging/go.d.version 2> /dev/null)"
  binary_version=$("${NETDATA_PREFIX}"/usr/libexec/netdata/plugins.d/go.d.plugin -v 2> /dev/null)

  govercomp "$version_in_file" "$binary_version"
  case $? in
    0) return 1 ;; # =
    2) return 1 ;; # <
    *) return 0 ;; # >, error
  esac
}

install_go() {
  if ! should_install_go; then
    return 0
  fi

  # When updating this value, ensure correct checksums in packaging/go.d.checksums
  GO_PACKAGE_VERSION="$(cat packaging/go.d.version)"
  ARCH_MAP=(
    'i386::386'
    'i686::386'
    'x86_64::amd64'
    'aarch64::arm64'
    'armv64::arm64'
    'armv6l::arm'
    'armv7l::arm'
    'armv5tel::arm'
  )

  progress "Install go.d.plugin"
  ARCH=$(uname -m)
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')

  for index in "${ARCH_MAP[@]}"; do
    KEY="${index%%::*}"
    VALUE="${index##*::}"
    if [ "$KEY" = "$ARCH" ]; then
      ARCH="${VALUE}"
      break
    fi
  done
  tmp="$(mktemp -d -t netdata-go-XXXXXX)"
  GO_PACKAGE_BASENAME="go.d.plugin-${GO_PACKAGE_VERSION}.${OS}-${ARCH}.tar.gz"

  if [ -z "${NETDATA_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN}" ]; then
    download_go "https://github.com/netdata/go.d.plugin/releases/download/${GO_PACKAGE_VERSION}/${GO_PACKAGE_BASENAME}" "${tmp}/${GO_PACKAGE_BASENAME}"
  else
    progress "Using provided go.d tarball ${NETDATA_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN}"
    run cp "${NETDATA_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN}" "${tmp}/${GO_PACKAGE_BASENAME}"
  fi

  if [ -z "${NETDATA_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN_CONFIG}" ]; then
    download_go "https://github.com/netdata/go.d.plugin/releases/download/${GO_PACKAGE_VERSION}/config.tar.gz" "${tmp}/config.tar.gz"
  else
    progress "Using provided config file for go.d ${NETDATA_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN_CONFIG}"
    run cp "${NETDATA_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN_CONFIG}" "${tmp}/config.tar.gz"
  fi

  if [ ! -f "${tmp}/${GO_PACKAGE_BASENAME}" ] || [ ! -f "${tmp}/config.tar.gz" ] || [ ! -s "${tmp}/config.tar.gz" ] || [ ! -s "${tmp}/${GO_PACKAGE_BASENAME}" ]; then
    run_failed "go.d plugin download failed, go.d plugin will not be available"
    defer_error "go.d plugin download failed, go.d plugin will not be available"
    echo >&2 "Either check the error or consider disabling it by issuing '--disable-go' in the installer"
    echo >&2
    return 0
  fi

  grep "${GO_PACKAGE_BASENAME}\$" "${INSTALLER_DIR}/packaging/go.d.checksums" > "${tmp}/sha256sums.txt" 2> /dev/null
  grep "config.tar.gz" "${INSTALLER_DIR}/packaging/go.d.checksums" >> "${tmp}/sha256sums.txt" 2> /dev/null

  # Checksum validation
  if ! (cd "${tmp}" && safe_sha256sum -c "sha256sums.txt"); then

    echo >&2 "go.d plugin checksum validation failure."
    echo >&2 "Either check the error or consider disabling it by issuing '--disable-go' in the installer"
    echo >&2

    run_failed "go.d.plugin package files checksum validation failed."
    defer_error "go.d.plugin package files checksum validation failed, go.d.plugin will not be available"
    return 0
  fi

  # Install new files
  run rm -rf "${NETDATA_STOCK_CONFIG_DIR}/go.d"
  run rm -rf "${NETDATA_STOCK_CONFIG_DIR}/go.d.conf"
  run tar -xf "${tmp}/config.tar.gz" -C "${NETDATA_STOCK_CONFIG_DIR}/"
  run chown -R "${ROOT_USER}:${ROOT_GROUP}" "${NETDATA_STOCK_CONFIG_DIR}"

  run tar xf "${tmp}/${GO_PACKAGE_BASENAME}"
  run mv "${GO_PACKAGE_BASENAME/\.tar\.gz/}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/go.d.plugin"
  if [ "${UID}" -eq 0 ]; then
    run chown "root:${NETDATA_GROUP}" "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/go.d.plugin"
  fi
  run chmod 0750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/go.d.plugin"
  rm -rf "${tmp}"
  return 0
}

install_go

function get_kernel_version() {
  r="$(uname -r | cut -f 1 -d '-')"

  read -r -a p <<< "$(echo "${r}" | tr '.' ' ')"

  printf "%03d%03d%03d" "${p[0]}" "${p[1]}" "${p[2]}"
}

function get_rh_version() {
  if [ ! -f /etc/redhat-release ]; then
    printf "000000000"
    return
  fi

  r="$(cut -f 4 -d ' ' < /etc/redhat-release)"

  read -r -a p <<< "$(echo "${r}" | tr '.' ' ')"

  printf "%03d%03d%03d" "${p[0]}" "${p[1]}" "${p[2]}"
}

detect_libc() {
  libc=
  if ldd --version 2>&1 | grep -q -i glibc; then
    echo >&2 " Detected GLIBC"
    libc="glibc"
  elif ldd --version 2>&1 | grep -q -i 'gnu libc'; then
    echo >&2 " Detected GLIBC"
    libc="glibc"
  elif ldd --version 2>&1 | grep -q -i musl; then
    echo >&2 " Detected musl"
    libc="musl"
  else
    echo >&2 " ERROR: Cannot detect a supported libc on your system!"
    return 1
  fi
  echo "${libc}"
  return 0
}

should_install_ebpf() {
  if [ "${NETDATA_DISABLE_EBPF:=0}" -eq 1 ]; then
    run_failed "eBPF explicitly disabled."
    defer_error "eBPF explicitly disabled."
    return 1
  fi

  if [ "$(uname -s)" != "Linux" ]; then
    run_failed "Currently eBPF is only supported on Linux."
    defer_error "Currently eBPF is only supported on Linux."
    return 1
  fi

  # Check Kernel Config
  if ! run "${INSTALLER_DIR}"/packaging/check-kernel-config.sh; then
    echo >&2 "Warning: Kernel unsupported or missing required config (eBPF may not work on your system)"
  fi

  return 0
}

remove_old_ebpf() {
  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ebpf_process.plugin" ]; then
    echo >&2 "Removing alpha eBPF collector."
    rm -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/ebpf_process.plugin"
  fi

  if [ -f "${NETDATA_PREFIX}/usr/lib/netdata/conf.d/ebpf_process.conf" ]; then
    echo >&2 "Removing alpha eBPF stock file"
    rm -f "${NETDATA_PREFIX}/usr/lib/netdata/conf.d/ebpf_process.conf"
  fi

  if [ -f "${NETDATA_PREFIX}/etc/netdata/ebpf_process.conf" ]; then
    echo >&2 "Renaming eBPF configuration file."
    mv "${NETDATA_PREFIX}/etc/netdata/ebpf_process.conf" "${NETDATA_PREFIX}/etc/netdata/ebpf.d.conf"
  fi

  # Added to remove eBPF programs with name pattern: NAME_VERSION.SUBVERSION.PATCH 
  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/pnetdata_ebpf_process.3.10.0.o" ]; then
    echo >&2 "Removing old eBPF programs with patch."
    rm -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/rnetdata_ebpf"*.?.*.*.o
    rm -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/pnetdata_ebpf"*.?.*.*.o
  fi

  # Remove old eBPF program to store new eBPF program inside subdirectory
  if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/pnetdata_ebpf_process.3.10.o" ]; then
    echo >&2 "Removing old eBPF programs installed in old directory."
    rm -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/rnetdata_ebpf"*.?.*.o
    rm -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/pnetdata_ebpf"*.?.*.o
  fi

  # Remove old reject list from previous directory
  if [ -f "${NETDATA_PREFIX}/usr/lib/netdata/conf.d/ebpf_kernel_reject_list.txt" ]; then
    echo >&2 "Removing old ebpf_kernel_reject_list.txt."
    rm -f "${NETDATA_PREFIX}/usr/lib/netdata/conf.d/ebpf_kernel_reject_list.txt"
  fi
}

install_ebpf() {
  if ! should_install_ebpf; then
    return 0
  fi

  remove_old_ebpf

  progress "Installing eBPF plugin"

  # Detect libc
  libc="${EBPF_LIBC:-"$(detect_libc)"}"

  EBPF_VERSION="$(cat packaging/ebpf.version)"
  EBPF_TARBALL="netdata-kernel-collector-${libc}-${EBPF_VERSION}.tar.xz"

  tmp="$(mktemp -d -t netdata-ebpf-XXXXXX)"

  if ! fetch_and_verify "ebpf" \
    "https://github.com/netdata/kernel-collector/releases/download/${EBPF_VERSION}/${EBPF_TARBALL}" \
    "${EBPF_TARBALL}" \
    "${tmp}" \
    "${NETDATA_LOCAL_TARBALL_OVERRIDE_EBPF}"; then
    run_failed "Failed to download eBPF collector package"
    echo 2>&" Removing temporary directory ${tmp} ..."
    rm -rf "${tmp}"
    return 1
  fi

  echo >&2 " Extracting ${EBPF_TARBALL} ..."
  tar -xf "${tmp}/${EBPF_TARBALL}" -C "${tmp}"

  # chown everything to root:netdata before we start copying out of our package
  run chown -R root:netdata "${tmp}"

  if [ ! -d "${NETDATA_PREFIX}"/usr/libexec/netdata/plugins.d/ebpf.d ]; then
    mkdir "${NETDATA_PREFIX}"/usr/libexec/netdata/plugins.d/ebpf.d
    RET=$?
    if [ "${RET}" != "0" ]; then
      rm -rf "${tmp}"
      return 1
    fi
  fi

  run cp -a -v "${tmp}"/*netdata_ebpf_*.o "${NETDATA_PREFIX}"/usr/libexec/netdata/plugins.d/ebpf.d

  rm -rf "${tmp}"

  return 0
}

progress "eBPF Kernel Collector"
install_ebpf

# -----------------------------------------------------------------------------
progress "Telemetry configuration"

if [ ! "${DO_NOT_TRACK:-0}" -eq 0 ] || [ -n "$DO_NOT_TRACK" ]; then
  NETDATA_DISABLE_TELEMETRY=1
fi

# Opt-out from telemetry program
if [ -n "${NETDATA_DISABLE_TELEMETRY+x}" ]; then
  run touch "${NETDATA_USER_CONFIG_DIR}/.opt-out-from-anonymous-statistics"
else
  printf "You can opt out from anonymous statistics via the --disable-telemetry option, or by creating an empty file %s \n\n" "${NETDATA_USER_CONFIG_DIR}/.opt-out-from-anonymous-statistics"
fi

# -----------------------------------------------------------------------------
progress "Install netdata at system init"

# By default we assume the shutdown/startup of the Netdata Agent are effectively
# without any system supervisor/init like SystemD or SysV. So we assume the most
# basic startup/shutdown commands...
NETDATA_STOP_CMD="${NETDATA_PREFIX}/usr/sbin/netdatacli shutdown-agent"
NETDATA_START_CMD="${NETDATA_PREFIX}/usr/sbin/netdata"

if grep -q docker /proc/1/cgroup > /dev/null 2>&1; then
  # If docker runs systemd for some weird reason, let the install proceed
  is_systemd_running="NO"
  if command -v pidof > /dev/null 2>&1; then
    is_systemd_running="$(pidof /usr/sbin/init || pidof systemd || echo "NO")"
  else
    is_systemd_running="$( (pgrep -q -f systemd && echo "1") || echo "NO")"
  fi

  if [ "${is_systemd_running}" == "1" ]; then
    echo >&2 "Found systemd within the docker container, running install_netdata_service() method"
    install_netdata_service || run_failed "Cannot install netdata init service."
  else
    echo >&2 "We are running within a docker container, will not be installing netdata service"
  fi
  echo >&2
else
  install_netdata_service || run_failed "Cannot install netdata init service."
fi

# -----------------------------------------------------------------------------
# check if we can re-start netdata

# TODO(paulfantom): Creation of configuration file should be handled by a build system. Additionally we shouldn't touch configuration files in /etc/netdata/...
started=0
if [ ${DONOTSTART} -eq 1 ]; then
  create_netdata_conf "${NETDATA_PREFIX}/etc/netdata/netdata.conf"
else
  if ! restart_netdata "${NETDATA_PREFIX}/usr/sbin/netdata" "${@}"; then
    fatal "Cannot start netdata!"
  fi

  started=1
  run_ok "netdata started!"
  create_netdata_conf "${NETDATA_PREFIX}/etc/netdata/netdata.conf" "http://localhost:${NETDATA_PORT}/netdata.conf"
fi
run chmod 0644 "${NETDATA_PREFIX}/etc/netdata/netdata.conf"

if [ "$(uname)" = "Linux" ]; then
  # -------------------------------------------------------------------------
  progress "Check KSM (kernel memory deduper)"

  ksm_is_available_but_disabled() {
    cat << KSM1

${TPUT_BOLD}Memory de-duplication instructions${TPUT_RESET}

You have kernel memory de-duper (called Kernel Same-page Merging,
or KSM) available, but it is not currently enabled.

To enable it run:

    ${TPUT_YELLOW}${TPUT_BOLD}echo 1 >/sys/kernel/mm/ksm/run${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}echo 1000 >/sys/kernel/mm/ksm/sleep_millisecs${TPUT_RESET}

If you enable it, you will save 40-60% of netdata memory.

KSM1
  }

  ksm_is_not_available() {
    cat << KSM2

${TPUT_BOLD}Memory de-duplication not present in your kernel${TPUT_RESET}

It seems you do not have kernel memory de-duper (called Kernel Same-page
Merging, or KSM) available.

To enable it, you need a kernel built with CONFIG_KSM=y

If you can have it, you will save 40-60% of netdata memory.

KSM2
  }

  if [ -f "/sys/kernel/mm/ksm/run" ]; then
    if [ "$(cat "/sys/kernel/mm/ksm/run")" != "1" ]; then
      ksm_is_available_but_disabled
    fi
  else
    ksm_is_not_available
  fi
fi

# -----------------------------------------------------------------------------
progress "Check version.txt"

if [ ! -s web/gui/version.txt ]; then
  cat << VERMSG

${TPUT_BOLD}Version update check warning${TPUT_RESET}

The way you downloaded netdata, we cannot find its version. This means the
Update check on the dashboard, will not work.

If you want to have version update check, please re-install it
following the procedure in:

https://docs.netdata.cloud/packaging/installer/

VERMSG
fi

if [ -f "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin" ]; then
  # -----------------------------------------------------------------------------
  progress "Check apps.plugin"

  if [ "${UID}" -ne 0 ]; then
    cat << SETUID_WARNING

${TPUT_BOLD}apps.plugin needs privileges${TPUT_RESET}

Since you have installed netdata as a normal user, to have apps.plugin collect
all the needed data, you have to give it the access rights it needs, by running
either of the following sets of commands:

To run apps.plugin with escalated capabilities:

    ${TPUT_YELLOW}${TPUT_BOLD}sudo chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}sudo chmod 0750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}sudo setcap cap_dac_read_search,cap_sys_ptrace+ep "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"${TPUT_RESET}

or, to run apps.plugin as root:

    ${TPUT_YELLOW}${TPUT_BOLD}sudo chown root:${NETDATA_GROUP} "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}sudo chmod 4750 "${NETDATA_PREFIX}/usr/libexec/netdata/plugins.d/apps.plugin"${TPUT_RESET}

apps.plugin is performing a hard-coded function of data collection for all
running processes. It cannot be instructed from the netdata daemon to perform
any task, so it is pretty safe to do this.

SETUID_WARNING
  fi
fi

# -----------------------------------------------------------------------------
progress "Copy uninstaller"
if [ -f "${NETDATA_PREFIX}"/usr/libexec/netdata-uninstaller.sh ]; then
  echo >&2 "Removing uninstaller from old location"
  rm -f "${NETDATA_PREFIX}"/usr/libexec/netdata-uninstaller.sh
fi

sed "s|ENVIRONMENT_FILE=\"/etc/netdata/.environment\"|ENVIRONMENT_FILE=\"${NETDATA_PREFIX}/etc/netdata/.environment\"|" packaging/installer/netdata-uninstaller.sh > ${NETDATA_PREFIX}/usr/libexec/netdata/netdata-uninstaller.sh
chmod 750 ${NETDATA_PREFIX}/usr/libexec/netdata/netdata-uninstaller.sh

# -----------------------------------------------------------------------------
progress "Basic netdata instructions"

cat << END

netdata by default listens on all IPs on port ${NETDATA_PORT},
so you can access it with:

  ${TPUT_CYAN}${TPUT_BOLD}http://this.machine.ip:${NETDATA_PORT}/${TPUT_RESET}

To stop netdata run:

  ${TPUT_YELLOW}${TPUT_BOLD}${NETDATA_STOP_CMD}${TPUT_RESET}

To start netdata run:

  ${TPUT_YELLOW}${TPUT_BOLD}${NETDATA_START_CMD}${TPUT_RESET}

END
echo >&2 "Uninstall script copied to: ${TPUT_RED}${TPUT_BOLD}${NETDATA_PREFIX}/usr/libexec/netdata/netdata-uninstaller.sh${TPUT_RESET}"
echo >&2

# -----------------------------------------------------------------------------
progress "Installing (but not enabling) the netdata updater tool"
cleanup_old_netdata_updater || run_failed "Cannot cleanup old netdata updater tool."
install_netdata_updater || run_failed "Cannot install netdata updater tool."

progress "Check if we must enable/disable the netdata updater tool"
if [ "${AUTOUPDATE}" = "1" ]; then
  enable_netdata_updater ${AUTO_UPDATE_TYPE} || run_failed "Cannot enable netdata updater tool"
else
  disable_netdata_updater || run_failed "Cannot disable netdata updater tool"
fi

# -----------------------------------------------------------------------------
progress "Wrap up environment set up"

# Save environment variables
echo >&2 "Preparing .environment file"
cat << EOF > "${NETDATA_USER_CONFIG_DIR}/.environment"
# Created by installer
PATH="${PATH}"
CFLAGS="${CFLAGS}"
LDFLAGS="${LDFLAGS}"
NETDATA_TMPDIR="${TMPDIR}"
NETDATA_PREFIX="${NETDATA_PREFIX}"
NETDATA_CONFIGURE_OPTIONS="${NETDATA_CONFIGURE_OPTIONS}"
NETDATA_ADDED_TO_GROUPS="${NETDATA_ADDED_TO_GROUPS}"
INSTALL_UID="${UID}"
NETDATA_GROUP="${NETDATA_GROUP}"
REINSTALL_OPTIONS="${REINSTALL_OPTIONS}"
RELEASE_CHANNEL="${RELEASE_CHANNEL}"
IS_NETDATA_STATIC_BINARY="${IS_NETDATA_STATIC_BINARY}"
NETDATA_LIB_DIR="${NETDATA_LIB_DIR}"
EOF
run chmod 0644 "${NETDATA_USER_CONFIG_DIR}/.environment"

echo >&2 "Setting netdata.tarball.checksum to 'new_installation'"
cat << EOF > "${NETDATA_LIB_DIR}/netdata.tarball.checksum"
new_installation
EOF

print_deferred_errors

# -----------------------------------------------------------------------------
echo >&2
progress "We are done!"

if [ ${started} -eq 1 ]; then
  netdata_banner "is installed and running now!"
else
  netdata_banner "is installed now!"
fi

echo >&2 "  enjoy real-time performance and health monitoring..."
echo >&2
exit 0
