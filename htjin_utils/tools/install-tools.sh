#!/bin/env bash
###############################################################################
# install-tools.sh
#
# Purpose : Prepare a z/OS sandbox environment and install development tools
#           (Java, Gradle, ZConfig, Wazi Deploy, TAZ).
#
# Usage   : ./install-tools.sh <user:password>
#           Credentials are for the Nexus Manzanita repository.
#
# Prerequisites:
#   - ZOAU installed and ZOAU_HOME set
#   - Network access to the Nexus repository
#   - Sufficient rights to modify SYS1.PROCLIB and SYS1.PARMLIB
#
# Warning:
#   - An IPL is required at the end of this script to activate IPv6
#     and certain PARMLIB settings.
###############################################################################

# --- Argument check ---------------------------------------------------------
if [ -z "$1" ]; then
  echo "Usage: $0 <user:password> [True]   # Nexus Manzanita credentials and True to update TAZ"
  exit 1
fi

set -e

# Directory containing this script (and the installation archives).
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
TOOLS_BIN_DIR=$SCRIPT_DIR
TARGET_INSTALL_DIR="/u/ibmuser/sandboxes/bank-of-z/tools"

# --- Variables --------------------------------------------------------------
# Nexus Manzanita credentials
CREDENTIALS="$1"
# Update TAZ
UPDATE_TAZ="${2:-False}"

# ============================================================
# 1. Create or refresh the sandbox zFS
# ============================================================
# if [ -d /usr/local/sandboxes ]; then
#     echo "==> /usr/local/sandboxes already exist."
# else
#     echo "==> Creating or refreshing the sandbox zFS"
#     sh ./mkzfs.sh -q SANDBOX -p 5000 -d /usr/local/sandboxes

# fi

# rm -rf /usr/local/sandboxes/tools
# mkdir -p /usr/local/sandboxes/tools

# # Increase the OMVS MEMLIMIT for IBMUSER (required by npm and Java workloads).
tsocmd "ALU IBMUSER OMVS(MEMLIMIT(32768M))"

# ============================================================
# 2. Add extra page sets
# ============================================================
echo "==> Adding extra page sets"
MAX_PAGES_SETS=7
FAILED=0
i=1
while [ "$i" -le "$((MAX_PAGES_SETS - 1))" ]; do
 echo "--- Page set [$i/$((MAX_PAGES_SETS - 1))] ---"
 if ./add-pageset.sh --apply --max-pages "$MAX_PAGES_SETS"; then
   echo "[$i] OK"
 else
   RC=$?
   FAILED=$((FAILED + 1))
   echo "ERROR: add-pageset.sh failed at iteration $i (rc=$RC)"
   exit $RC
 fi
 i=$((i + 1))
done

# ============================================================
# 3. Download archives from Nexus
# ============================================================
# echo "==> Downloading tools"
# AUTH="$1"
# BASE_URL="http://zdevops-demo1.fyre.ibm.com:8888/repository/manzanita/tools"

# files=(
#   "gradle-9.5.1-bin.zip"
#   "ibm-semeru-certified-jdk_s390x_zos_21.0.10.1.pax.Z"
#   "zconfig-0.4.1.dev1-py3-none-any.whl"
#   "cics-resource-builder-1.0.6.zip"
#   "wazideploy-3.0.7.3-py3.14-none-any.whl"
#   "dbb-3.0.4.1-war-fix.tar"
# )

# for file in "${files[@]}"; do
#   if [ -f "$file" ]; then
#     echo "  $file already exists, skipping."
#   else
#     echo "  Downloading $file..."
#     curl -u "$AUTH" -O "$BASE_URL/$file"
#     chtag -r "$file"
#   fi
# done


# ============================================================
# 4. Install ZConfig (dedicated Python virtual environment)
# ============================================================
echo "==> Installing ZConfig"
cd $TARGET_INSTALL_DIR
export ZOAU_HOME=$TARGET_INSTALL_DIR/zoautils
python3 -m venv zconfig
. zconfig/bin/activate
pip3 install "$ZOAU_HOME/zoautil_py-1.4.1.1-cp314-cp314-zos.whl"
pip3 install "$TOOLS_BIN_DIR/zconfig-0.4.1.dev1-py3-none-any.whl"
pip3 list
deactivate

# ============================================================
# 5. Install Wazi Deploy (GDP Python environment)
# ============================================================
# echo "==> Installing Wazi Deploy"
# cd TARGET_INSTALL_DIR
# . /global/opt/pyenv/gdp/bin/activate
# pip3 install "$TOOLS_BIN_DIR/wazideploy-3.0.7.3-py3.14-none-any.whl"
# pip3 install "$ZOAU_HOME/zoautil_py-1.4.1.0-cp314-cp314-zos.whl"
# pip3 list
# deactivate

# ============================================================
# 6. Install the CICS Resource Builder
# ============================================================
echo "==> Installing CICS Resource Builder"
cd $TARGET_INSTALL_DIR
mkdir -p zrb && cd zrb
jar xf "$TOOLS_BIN_DIR/cics-resource-builder-1.0.6.zip"
chmod +x cics-resource-builder-1.0.6/bin/zrb
chtag -tc ISO8859-1 cics-resource-builder-1.0.6/bin/zrb
cics-resource-builder-1.0.6/bin/zrb

# ============================================================
# 7. Install Java 21.0.10.1
# Note: Java 21 on ZDVT has encoding issues with Gradle.
# ============================================================
# echo "==> Installing Java 21.0.10.1"
# cd TARGET_INSTALL_DIR
# pax -pp -rzf "$TOOLS_BIN_DIR/ibm-semeru-certified-jdk_s390x_zos_21.0.10.1.pax.Z"
# extattr +a $(find J21.0_64 -name libj9ifa29.so)

# ============================================================
# 8. Install Gradle
# ============================================================
echo "==> Installing Gradle"
cd $TARGET_INSTALL_DIR
jar xf "$TOOLS_BIN_DIR/gradle-9.5.1-bin.zip"
chmod +x gradle-9.5.1/bin/gradle
export JAVA_HOME=/usr/lpp/java/java21/current_64
export GRADLE_OPTS="-Dfile.encoding=UTF-8"
export GRADLE_USER_HOME=$PWD
$TARGET_INSTALL_DIR/gradle-9.5.1/bin/gradle build help


# ============================================================
# 9. Install DBB Fix for WAR file packing
# ============================================================
echo "==> Install DBB Fix for WAR file packing"
cd $TARGET_INSTALL_DIR
tar -xf "$TOOLS_BIN_DIR/dbb-3.0.4.1-war-fix.tar"

# ============================================================
# 10. Enable IPv6 (requires IPL to fully take effect)
# ============================================================
echo "==> Enabling IPv6"
cd "$SCRIPT_DIR"
sh ./enable-ipv6.sh

echo ""
echo "WARNING: AN IPL MAY BE REQUIRED â READ THE MANUAL STEPS ABOVE."