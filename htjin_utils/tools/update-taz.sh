#!/bin/env bash
###############################################################################
# install-taz.sh
#
# Purpose : Install and configure IBM Test Accelerator for z (TAZ)
#           and the z/OS Debugger runtime environment.
#
# Usage   : ./install-taz.sh <user:password>
#           Credentials are for the Nexus Manzanita repository.
# Prerequisites:
#   - ZOAU installed and ZOAU_HOME set
#   - Network access to the Nexus repository
#   - Sufficient rights to modify SYS1.PROCLIB and SYS1.PARMLIB
###############################################################################

# --- Argument check ---------------------------------------------------------
if [ -z "$1" ]; then
  echo "Usage: $0 <user:password># Nexus Manzanita credentials"
  exit 1
fi

set -e

# ============================================================
# 0. Download archives from Nexus
# ============================================================
echo "==> Downloading tools"
AUTH="$1"
BASE_URL="http://zdevops-demo1.fyre.ibm.com:8888/repository/manzanita/tools"

files=(
  "vhr0m0.manz.pds.trs"
  "taz-280.tar"
)

for file in "${files[@]}"; do
  if [ -f "$file" ]; then
    echo "  $file already exists, skipping."
  else
    echo "  Downloading $file..."
    curl -u "$AUTH" -O "$BASE_URL/$file"
    chtag -r "$file"
  fi
done

# ============================================================
# 1. Stop active regions before TAZ installation
#    SEQAAUTH and SEQAMOD must not be allocated during install.
# ============================================================
echo "==> Stopping active regions (DBGMGR, CICS, IMS)"
opercmd "C DBGMGR"
opercmd "C CICSTS63"
opercmd "C CICSCBSA"

# Graceful IMS shutdown via checkpoint FREEZE.
REPLID=$(opercmd 'D R,JOB=IMS15CR1' | grep "IMS READY" | awk '{print $1}')
echo "IMS REPLID: $REPLID"
opercmd "$REPLID,/CHE FREEZE"

# ============================================================
# 2. Install the TAZ CLI
# ============================================================
echo "==> Installing TAZ CLI"
cd /usr/local/sandboxes/tools/
tar xf "$TOOLS_BIN_DIR/taz-280.tar"

# ============================================================
# 3. Submit the TAZ driver installation JCL
# ============================================================

# Utility function: submit a JCL file and wait for completion.
# Returns 0 if CC=0000 or CC=0004, otherwise returns 8.
run_job_and_wait() {
  local JCLFILE="$1"

  echo "==> Submitting $JCLFILE via jsub..."
  OUT=$(jsub -f "$JCLFILE")
  echo "$OUT"

  JOBID=$(echo "$OUT" | awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /^JOB[0-9]+$/) { print $i; exit }
    }
  }')

  [ -z "$JOBID" ] && {
    echo "ERROR: no JOBID returned by jsub"
    return 8
  }

  echo "Waiting for job $JOBID..."

  while :; do
    LINE=$(jls "$JOBID" 2>/dev/null | grep "$JOBID" | tail -1 || true)

    [ -n "$LINE" ] && echo "$LINE"

    echo "$LINE" | grep -Eq \
      "OUTPUT|CC |ABEND|JCLERR|CANCELED|SEC ERROR" && break

    sleep 5
  done

  echo "===== FINAL STATUS ====="
  jls "$JOBID" || true

  echo "===== JESYSMSG ====="
  pjdd "$JOBID" JES2 JESYSMSG 2>/dev/null || true

  FINAL=$(jls "$JOBID" | grep "$JOBID" | tail -1)

  echo "$FINAL" | awk '{
    if ($4=="CC" && ($5=="0000" || $5=="0004"))
      exit 0
    else
      exit 1
  }' && return 0

  echo "ERROR: Job failed: $JOBID"
  return 8
}

JCL_TEMPLATE="$SCRIPT_DIR/jcl/install-taz-driver.jcl"
JCL_TMP="/tmp/install-taz-driver.$$.jcl"

[ ! -f "$JCL_TEMPLATE" ] && {
  echo "ERROR: JCL template not found: $JCL_TEMPLATE"
  exit 8
}

# Create a symlink so the JCL can reference a stable path.
rm -rf /tmp/taz_tools
ln -sf "$TOOLS_BIN_DIR" /tmp/taz_tools

# Substitute the placeholder and convert to EBCDIC before submission.
sed "s|#TOOLS_BIN_DIR|/tmp/taz_tools|g" \
  "$JCL_TEMPLATE" > "$JCL_TMP"

if ! iconv -f ISO8859-1 -t IBM-1047 \
  "$JCL_TMP" > "${JCL_TMP}.ebcdic.jcl"
then
  echo "ERROR: iconv to EBCDIC failed"
  exit 1
fi

chtag -r "${JCL_TMP}.ebcdic.jcl"

run_job_and_wait "${JCL_TMP}.ebcdic.jcl" || {
  echo "ERROR: TAZ driver JCL failed"
  rm -f "$JCL_TMP" "${JCL_TMP}.ebcdic.jcl"
  exit 8
}

echo "Job $JOBID completed successfully"

rm -f "$JCL_TMP" "${JCL_TMP}.ebcdic.jcl"

# ============================================================
# 4. Update z/OS Debugger procedures in SYS1.PROCLIB
# ============================================================
echo "==> Updating z/OS Debugger PROCLIB procedures"

# Stop Debugger services if currently active.
opercmd "C EQAPROF" 2>/dev/null || true
opercmd "C DBGMGR"  2>/dev/null || true

# Copy and patch the EQAPPLAY sample procedure.
cp "//'EQAW.VHR0M0.PTF.SEQASAMP(EQAPPLAY)'" /tmp/EQAPPLAY

sed "s#//            EQA='EQAW',#//            EQA='EQAW.VHR0M0.PTF',#" \
  /tmp/EQAPPLAY > /tmp/EQAPPLAY.new

iconv -f ISO8859-1 -t IBM-1047 \
  /tmp/EQAPPLAY.new > /tmp/EQAPPLAY.ebc

cp /tmp/EQAPPLAY.ebc "//'SYS1.PROCLIB(EQAPPLAY)'"

rm -f /tmp/EQAPPLAY*

# Update EQAHLQ in installed procedures.
DEBUGGER_EQAHLQ="EQAW.VHR0M0.PTF"
PROCLIB_TMP="/tmp/proclib-member.$$.txt"

update_proclib_member() {
  local member="$1"
  local dataset="SYS1.PROCLIB(${member})"

  echo "  Updating ${dataset}"

  cp "//'${dataset}'" "$PROCLIB_TMP"

  sed \
    "s/'EQAW'/'${DEBUGGER_EQAHLQ}'/g; s/EQAW$/${DEBUGGER_EQAHLQ}/g" \
    "$PROCLIB_TMP" > "${PROCLIB_TMP}.new"

  if ! iconv -f ISO8859-1 -t IBM-1047 \
    "${PROCLIB_TMP}.new" > "${PROCLIB_TMP}.new.iconv"
  then
    echo "ERROR: iconv to EBCDIC failed for ${dataset}"
    exit 1
  fi

  chtag -r "${PROCLIB_TMP}.new.iconv"

  cp "${PROCLIB_TMP}.new.iconv" "//'${dataset}'"

  rm -f \
    "$PROCLIB_TMP" \
    "${PROCLIB_TMP}.new" \
    "${PROCLIB_TMP}.new.iconv"
}

update_proclib_member "EQAPPLAY"
update_proclib_member "EQAPROF"
update_proclib_member "DBGMGR"

# ============================================================
# 5. Make SEQAAUTH APF authorization persistent
# ============================================================
echo "==> Making SEQAAUTH APF authorization persistent"

APF_DSN="EQAW.VHR0M0.PTF.SEQAAUTH"

APF_VOLUME=$(dls -u "$APF_DSN" 2>/dev/null | awk '
  NF { print $NF; exit }
')

[ -z "$APF_VOLUME" ] && {
  echo "ERROR: cannot determine volume for ${APF_DSN}"
  exit 8
}

# Add APF dynamically for current IPL.
opercmd \
  "SETPROG APF,ADD,DSN=${APF_DSN},VOL=${APF_VOLUME}" \
  2>/dev/null || true

# Determine active IEASYSxx member.
IPLINFO=$(opercmd "D IPLINFO")

IEASYS_LIST=$(echo "$IPLINFO" |
  sed -n "s/.*IEASYS LIST = (\([^)]*\)).*/\1/p" |
  tr -d ' '
)

[ -z "$IEASYS_LIST" ] && {
  echo "ERROR: cannot find IEASYS LIST"
  exit 8
}

IEASYS_MEMBER=$(echo "$IEASYS_LIST" | cut -d',' -f1)

IEASYS_TMP="/tmp/IEASYS${IEASYS_MEMBER}.$$"

cp "//'SYS1.PARMLIB(IEASYS${IEASYS_MEMBER})'" "$IEASYS_TMP"

PROG_LINE=$(grep -i "^[[:space:]]*PROG=" \
  "$IEASYS_TMP" | head -1 || true)

rm -f "$IEASYS_TMP"

[ -z "$PROG_LINE" ] && {
  echo "ERROR: cannot find PROG="
  exit 8
}

PROG_LIST=$(echo "$PROG_LINE" |
  sed -n "s/.*PROG=(\([^)]*\)).*/\1/p" |
  tr -d ' '
)

[ -z "$PROG_LIST" ] && \
PROG_LIST=$(echo "$PROG_LINE" |
  sed -n "s/.*PROG=\([^, ]*\).*/\1/p" |
  tr -d ' '
)

[ -z "$PROG_LIST" ] && {
  echo "ERROR: cannot parse PROG="
  exit 8
}

IFS=',' read -r -a PROG_MEMBERS <<< "$PROG_LIST"

SELECTED_PROG=""
LAST_INDEX=$((${#PROG_MEMBERS[@]} - 1))
CHECK_TMP="/tmp/progcheck.$$"

for ((idx=LAST_INDEX; idx>=0; idx--)); do
  candidate="${PROG_MEMBERS[$idx]}"

  if cp "//'SYS1.PARMLIB(PROG${candidate})'" \
    "$CHECK_TMP" 2>/dev/null
  then
    SELECTED_PROG="$candidate"
    rm -f "$CHECK_TMP"
    break
  fi

  rm -f "$CHECK_TMP"
done

[ -z "$SELECTED_PROG" ] && \
  SELECTED_PROG="${PROG_MEMBERS[0]}"

PROG_DSN="SYS1.PARMLIB(PROG${SELECTED_PROG})"

PROG_TMP="/tmp/PROG${SELECTED_PROG}.$$"
PROG_NEW="${PROG_TMP}.new"

APF_LINE="APF ADD DSNAME(${APF_DSN}) VOLUME(${APF_VOLUME})"

echo "  IEASYS member : IEASYS${IEASYS_MEMBER}"
echo "  PROG list     : $PROG_LIST"
echo "  Target member : $PROG_DSN"

cp "//'${PROG_DSN}'" "$PROG_TMP"

if grep -q "$APF_DSN" "$PROG_TMP"; then
  echo "  ${APF_DSN} already present."
else
  {
    cat "$PROG_TMP"
    echo "$APF_LINE"
  } | iconv -f ISO8859-1 -t IBM-1047 > "$PROG_NEW"

  chtag -r "$PROG_NEW" 2>/dev/null || true

  dcp -f "$PROG_NEW" "${PROG_DSN}"

  echo "  Updated ${PROG_DSN}."
fi

rm -f "$PROG_TMP" "$PROG_NEW"

# Activate immediately.
opercmd "SET PROG=${SELECTED_PROG}" 2>/dev/null || true

# Restart debugger services.
opercmd "S EQAPROF" 2>/dev/null || true
opercmd "S DBGMGR"  2>/dev/null || true

# ============================================================
# 6. Enable IBM Test Accelerator for z in IFAPRD00
# ============================================================
echo "==> Checking IBM Test Accelerator for z product state"

TMP_PARMLIB="/tmp/ifaprd00-$$.txt"
TMP_PARMLIB_EBCDIC="/tmp/ifaprd00-$$.ebcdic"

if opercmd "D PROD,STATE" | grep -q "Test Accel for z"; then

  echo "  Test Accel for z already enabled."

else

  echo "  Updating SYS1.PARMLIB(IFAPRD00)..."

  dcat "SYS1.PARMLIB(IFAPRD00)" \
    > "$TMP_PARMLIB" 2>/dev/null || true

  if ! grep -q "Test Accel for z" "$TMP_PARMLIB"; then

cat << 'EOF' >> "$TMP_PARMLIB"

PRODUCT OWNER('IBM CORP')
        NAME('Test Accel for z')
        ID(5900-BBG)
        VERSION(*) RELEASE(*) MOD(*)
        FEATURENAME(*)
        STATE(ENABLED)
EOF

  fi

  if ! grep -q "IBM APP DLIV FND" "$TMP_PARMLIB"; then

cat << 'EOF' >> "$TMP_PARMLIB"

PRODUCT OWNER('IBM CORP')
        NAME('IBM APP DLIV FND')
        ID(5755-AB1)
        VERSION(*) RELEASE(*) MOD(*)
        FEATURENAME(*)
        STATE(ENABLED)
EOF

  fi

  iconv -f ISO8859-1 -t IBM-1047 \
    "$TMP_PARMLIB" > "$TMP_PARMLIB_EBCDIC"

  chtag -r "$TMP_PARMLIB_EBCDIC"

  dcp -f "$TMP_PARMLIB_EBCDIC" \
    "SYS1.PARMLIB(IFAPRD00)"

  opercmd "SET PROD=00"

fi

echo "==> Verifying TAZ product state"

opercmd "D PROD,STATE" |
  grep -E "TAZ|Test Accel for z" || true

rm -f "$TMP_PARMLIB" "$TMP_PARMLIB_EBCDIC"

# ============================================================
# 7. Check GRS enqueues on debugger datasets
# ============================================================
echo "==> Checking GRS enqueues"

opercmd "D GRS,RES=(SYSDSN,IDZ.V17R0M0.SEQABMOD)"
opercmd "D GRS,RES=(SYSDSN,IDZ.V17R0M0.SEQAMOD)"

# ============================================================
# 8. Manual post-install steps
# ============================================================

cat << 'EOF'

======================================================================
MANUAL POST-INSTALL STEPS REQUIRED
======================================================================

1. Get the volume for EQAW.VHR0M0.PTF.SEQABMOD:
     dls -l EQAW.VHR0M0.PTF.SEQABMOD

2. Update SYS1.PARMLIB(PROG00):
     LNKLST ADD NAME(R31.LNK)
             DSNAME(IDZ.V17R0M0.SEQAMOD)
             VOLUME(<VOL>)

     LNKLST ADD NAME(R31.LNK)
             DSNAME(IDZ.V17R0M0.SEQABMOD)
             VOLUME(<VOL>)

3. Update SYS1.PARMLIB(PROG01):
     APF ADD DSNAME(IDZ.V17R0M0.SEQAMOD)
             VOLUME(<VOL>)

     APF ADD DSNAME(IDZ.V17R0M0.SEQABMOD)
             VOLUME(<VOL>)

4. Update IMSV15.PROCLIB(DFSMPR):
     // DD DSN=EQAW.SEQAMOD,DISP=SHR
     ->
     // DD DSN=EQAW.VHR0M0.PTF.SEQAMOD,DISP=SHR

5. Update SYS1.PROCLIB(CICSTS63):
     // DD DSN=EQAW.SEQAMOD,DISP=SHR
     ->
     // DD DSN=EQAW.VHR0M0.PTF.SEQAMOD,DISP=SHR

6. IPL the system.

======================================================================

EOF

# ============================================================
# 9. Restart regions
# ============================================================
echo "==> Restarting regions"

opercmd "S DBGMGR"
opercmd "S CICSTS63"
opercmd "S CICSCBSA"
echo "WARNING: AN IPL MAY BE REQUIRED."