# install-tools.sh - Detailed Technical Documentation

## 1. Purpose

`install-tools.sh` prepares a z/OS sandbox environment and installs a set of development and testing tools used around IBM z/OS Debugger, TAZ, Wazi Deploy, ZConfig, Java, Gradle, and related tooling.

The script is intended to automate a lab or sandbox setup. It performs storage preparation, tool installation, system configuration, debugger setup, APF authorization, product enablement, and IPv6 preparation.

This script makes system-level changes. It should be run only by a user with sufficient authority to update z/OS datasets, RACF definitions, PARMLIB members, PROCLIB members, APF settings, and OMVS configuration.

---

## 2. Required Input

The script requires one argument:

```sh
./install-tools.sh <user:password>
```

The argument is used as Nexus repository credentials for downloading installation archives and tool packages.

If no argument is provided, the script prints:

```text
Usage: ./install-tools.sh <user:password> # This is the Nexus Manzanita credentials
```

and exits with return code `1`.

---

## 3. Execution Behavior

The script starts with:

```sh
set -e
```

This means that most failing commands stop the script immediately.

Some commands are intentionally allowed to fail without stopping the script by using:

```sh
|| true
```

This is used mostly for operations where the target may already be stopped, already configured, or not currently active.

---

## 4. High-Level Workflow

The script performs the following major steps:

1. Resolve the script directory.
2. Create or refresh the sandbox zFS.
3. Recreate `/usr/local/sandboxes/tools`.
4. Increase the OMVS MEMLIMIT for `IBMUSER`.
5. Add extra page sets.
6. Download tool archives from Nexus.
7. Install ZConfig into a dedicated Python virtual environment.
8. Install Wazi Deploy into the GDP Python environment.
9. Install CICS Resource Builder.
10. Install IBM Semeru Java 17.
11. Install Gradle.
12. Install TAZ CLI.
13. Submit TAZ driver installation JCL.
14. Update z/OS Debugger PROCLIB procedures.
15. Make `SEQAAUTH` APF authorization persistent.
16. Enable IBM Test Accelerator for z in `IFAPRD00`.
17. Print manual follow-up actions for LNKLST, APF, IMS, and CICS.
18. Enable IPv6 configuration through `enable-ipv6.sh`.
19. Warn that an IPL may be required.

---

## 5. Directory Resolution

The script determines where it is located:

```sh
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
TOOLS_BIN_DIR=$SCRIPT_DIR
```

`SCRIPT_DIR` is used later to locate helper scripts, local archives, and the JCL template.

`TOOLS_BIN_DIR` points to the same directory and is used as the source location for downloaded installation files.

---

## 6. Sandbox zFS Creation

The script creates or refreshes a sandbox zFS by calling:

```sh
sh ./mkzfs.sh -q SANDBOX -p 5000 -d /usr/local/sandboxes
```

This delegates the storage creation to `mkzfs.sh`.

Expected result:

- zFS qualifier: `SANDBOX`
- Primary size: `5000` MB
- Mount directory: `/usr/local/sandboxes`

The script then removes and recreates the tools directory:

```sh
rm -rf /usr/local/sandboxes/tools
mkdir -p /usr/local/sandboxes/tools
```

This means any existing content under `/usr/local/sandboxes/tools` is deleted.

---

## 7. OMVS MEMLIMIT Update

The script increases the OMVS memory limit for `IBMUSER`:

```sh
tsocmd "ALU IBMUSER OMVS(MEMLIMIT(32768M))"
```

This is required for npm, Java, Gradle, or other memory-heavy workloads.

There is also a commented-out command:

```sh
# opercmd "SETOMVS MAXASSIZE=2147483647"
```

It is not executed.

---

## 8. Adding Extra Page Sets

The script sets:

```sh
MAX_PAGES_SETS=7
```

Then it runs `add-pageset.sh` repeatedly:

```sh
./add-pageset.sh --apply --max-pages $MAX_PAGES_SETS
```

The loop runs from `1` to `MAX_PAGES_SETS - 1`, so it attempts up to six iterations.

The purpose is to ensure enough auxiliary page datasets exist for the workload.

If any `add-pageset.sh` execution fails, the script stops and exits with the same return code.

Important note: the script prints variables named `PAGES_SETS` and `FAILED`, but those variables are not initialized in the visible script. This may affect displayed messages or failure counting, but the failure path still exits immediately.

---

## 9. Downloading Tool Archives

The script downloads tool files from:

```text
http://zdevops-demo1.fyre.ibm.com:8888/repository/manzanita/tools
```

Authentication uses the first script argument:

```sh
AUTH="$1"
curl -u "$AUTH" -O "$BASE_URL/$file"
```

The file list is:

```text
gradle-9.4.1-bin.zip
ibm-semeru-certified-jdk_s390x_zos_17.0.18.0.pax.Z
zconfig-0.3.0-py3-none-any.whl
cics-resource-builder-1.0.6.zip
wazideploy-3.0.7.2-py3.14-none-any.whl
vhr0m0.manz.pds.trs
taz-280.tar
```

If a file already exists in the script directory, it is skipped.

After download, the script removes file tagging with:

```sh
chtag -r $file
```

---

## 10. ZConfig Installation

The script creates a dedicated Python virtual environment:

```sh
cd /usr/local/sandboxes/tools/
python3 -m venv zconfig
. zconfig/bin/activate
```

It installs:

```sh
pip3 install "$ZOAU_HOME/zoautil_py-1.4.1.0-cp314-cp314-zos.whl"
pip3 install "$TOOLS_BIN_DIR/zconfig-0.3.0-py3-none-any.whl"
```

Then it lists installed packages and deactivates the environment.

Result:

- ZConfig is installed in `/usr/local/sandboxes/tools/zconfig`
- ZOAU Python bindings are installed in the same virtual environment

---

## 11. Wazi Deploy Installation

The script activates the GDP Python environment:

```sh
. /global/opt/pyenv/gdp/bin/activate
```

It installs:

```sh
pip3 install "$TOOLS_BIN_DIR/wazideploy-3.0.7.2-py3.14-none-any.whl"
pip3 install "$ZOAU_HOME/zoautil_py-1.4.1.0-cp314-cp314-zos.whl"
```

Then it lists installed packages and deactivates the environment.

Result:

- Wazi Deploy is installed into the existing GDP Python environment
- ZOAU Python bindings are installed there as well

---

## 12. CICS Resource Builder Installation

The script creates a `zrb` directory:

```sh
mkdir zrb
cd zrb
```

It extracts:

```sh
jar xf "$TOOLS_BIN_DIR/cics-resource-builder-1.0.6.zip"
```

Then it makes the binary executable and sets tagging:

```sh
chmod +x cics-resource-builder-1.0.6/bin/zrb
chtag -tc ISO8859-1 cics-resource-builder-1.0.6/bin/zrb
```

Finally, it runs:

```sh
cics-resource-builder-1.0.6/bin/zrb
```

This likely validates that the tool starts correctly.

---

## 13. Java 17 Installation

The script extracts IBM Semeru Java 17:

```sh
pax -pp -rzf "$TOOLS_BIN_DIR/ibm-semeru-certified-jdk_s390x_zos_17.0.18.0.pax.Z"
```

Then it applies an extended attribute to `libj9ifa29.so`:

```sh
extattr +a $(find J17.0_64 -name libj9ifa29.so)
```

The script comment indicates Java 17 is required for Gradle, while Java 21 has encoding issues in this setup.

---

## 14. Gradle Installation

The script extracts Gradle:

```sh
jar xf "$TOOLS_BIN_DIR/gradle-9.4.1-bin.zip"
```

It makes Gradle executable:

```sh
chmod +x gradle-9.4.1/bin/gradle
```

Then it sets:

```sh
export JAVA_HOME=/usr/local/sandboxes/tools/J17.0_64
export GRADLE_OPTS="-Dfile.encoding=UTF-8"
```

These settings apply to the current script execution.

---

## 15. TAZ CLI Installation

The script extracts:

```sh
tar xf "$TOOLS_BIN_DIR/taz-280.tar"
```

This installs or unpacks the TAZ CLI into `/usr/local/sandboxes/tools`.

---

## 16. TAZ Driver Installation JCL

The script defines a helper function named `run_job_and_wait`.

This function:

1. Submits a JCL file using `jsub`.
2. Extracts the returned JES job ID.
3. Waits until the job reaches a final state.
4. Prints final job status.
5. Prints `JESYSMSG`.
6. Treats condition codes `0000` and `0004` as success.
7. Returns `8` on failure.

The JCL template path is:

```sh
$SCRIPT_DIR/jcl/install-taz-driver.jcl
```

The generated temporary JCL file is:

```sh
/tmp/install-taz-driver.$$.jcl
```

The script replaces the placeholder:

```text
#TOOLS_BIN_DIR
```

with:

```text
/tmp/taz_tools
```

It creates `/tmp/taz_tools` as a symbolic link to the tools source directory:

```sh
ln -sf "$TOOLS_BIN_DIR" "/tmp/taz_tools"
```

Then the JCL is converted to EBCDIC:

```sh
iconv -f ISO8859-1 -t IBM-1047 "${JCL_TMP}" > "${JCL_TMP}.ebcdic.jcl"
```

The EBCDIC JCL is submitted with `run_job_and_wait`.

---

## 17. z/OS Debugger PROCLIB Updates

The script stops these services if they are running:

```sh
opercmd "C EQAPROF" 2>/dev/null || true
opercmd "C DBGMGR" 2>/dev/null || true
```

Then it copies the `EQAPPLAY` sample procedure:

```sh
cp "//'EQAW.VHR0M0.PTF.SEQASAMP(EQAPPLAY)'" /tmp/EQAPPLAY
```

It changes the EQA high-level qualifier from:

```text
EQAW
```

to:

```text
EQAW.VHR0M0.PTF
```

Then it writes the result to:

```text
SYS1.PROCLIB(EQAPPLAY)
```

The script defines:

```sh
DEBUGGER_EQAHLQ="EQAW.VHR0M0.PTF"
```

Then it updates these PROCLIB members:

```text
SYS1.PROCLIB(EQAPPLAY)
SYS1.PROCLIB(EQAPROF)
SYS1.PROCLIB(DBGMGR)
```

The update replaces references to:

```text
'EQAW'
```

and some line-ending `EQAW` values with:

```text
EQAW.VHR0M0.PTF
```

Each member is converted back to EBCDIC before being copied to `SYS1.PROCLIB`.

---

## 18. Persistent APF Authorization for SEQAAUTH

The script sets:

```sh
APF_DSN="EQAW.VHR0M0.PTF.SEQAAUTH"
```

It detects the volume of that dataset:

```sh
APF_VOLUME=$(dls -u "$APF_DSN" 2>/dev/null | awk 'NF {print $NF; exit}')
```

It dynamically APF-authorizes the dataset for the current IPL:

```sh
opercmd "SETPROG APF,ADD,DSN=${APF_DSN},VOL=${APF_VOLUME}" 2>/dev/null || true
```

Then it discovers the active IEASYS list:

```sh
opercmd "D IPLINFO"
```

It reads the active `IEASYSxx` member from:

```text
SYS1.PARMLIB
```

and parses the `PROG=` statement.

It selects the last existing `PROGxx` member from the PROG list. This is probably intended to use the local or site override member.

It appends this line if it is not already present:

```text
APF ADD DSNAME(EQAW.VHR0M0.PTF.SEQAAUTH) VOLUME(<detected-volume>)
```

Then it writes the updated member back to:

```text
SYS1.PARMLIB(PROGxx)
```

Finally, it reprocesses the selected PROG member:

```sh
opercmd "SET PROG=${SELECTED_PROG}" 2>/dev/null || true
```

Then it restarts:

```sh
opercmd "S EQAPROF" 2>/dev/null || true
opercmd "S DBGMGR" 2>/dev/null || true
```

---

## 19. IBM Test Accelerator for z Product Enablement

The script checks whether the product is already active:

```sh
opercmd "D PROD,STATE" | grep -q "Test Accel for z"
```

If not present, it updates:

```text
SYS1.PARMLIB(IFAPRD00)
```

It appends a product entry for:

```text
Test Accel for z
ID: 5900-BBG
STATE: ENABLED
```

It also appends a product entry for:

```text
IBM APP DLIV FND
ID: 5755-AB1
STATE: ENABLED
```

The script avoids duplicate entries by checking whether the text already exists in `IFAPRD00`.

After updating the member, it refreshes product definitions:

```sh
opercmd "SET PROD=00"
```

Then it verifies:

```sh
opercmd "D PROD,STATE" | grep -E "TAZ|Test Accel for z" || true
```

---

## 20. GRS Resource Checks

The script displays GRS information for:

```text
SYSDSN,IDZ.V17R0M0.SEQABMOD
SYSDSN,IDZ.V17R0M0.SEQAMOD
```

Commands:

```sh
opercmd "D GRS,RES=(SYSDSN,IDZ.V17R0M0.SEQABMOD)"
opercmd "D GRS,RES=(SYSDSN,IDZ.V17R0M0.SEQAMOD)"
```

This helps identify whether these datasets are allocated, locked, or in use.

---

## 21. Manual Follow-Up Instructions Printed by the Script

The script prints manual instructions for additional configuration.

It tells the operator to:

1. Get the volume for `EQAW.VHR0M0.PTF.SEQABMOD`.
2. Modify `SYS1.PARMLIB(PROG00)` with LNKLST entries.
3. Modify `SYS1.PARMLIB(PROG01)` with APF entries.
4. Update IMS procedure `IMSV15.PROCLIB(DFSMPR)`.
5. Update CICS procedure `SYS1.PROCLIB(CICSTS63)`.
6. IPL the system.

The printed LNKLST examples are:

```text
LNKLST ADD NAME(R31.LNK) DSNAME(IDZ.V17R0M0.SEQAMOD)  VOLUME(!!VOLUME!!)
LNKLST ADD NAME(R31.LNK) DSNAME(IDZ.V17R0M0.SEQABMOD) VOLUME(!!VOLUME!!)
```

The printed APF examples are:

```text
APF ADD DSNAME(IDZ.V17R0M0.SEQAMOD)     VOLUME(!!VOLUME!!)
APF ADD DSNAME(IDZ.V17R0M0.SEQABMOD)    VOLUME(!!VOLUME!!)
```

The script does not perform these updates automatically. It only prints the instructions.

---

## 22. IPv6 Enablement

At the end, the script runs:

```sh
sh ./enable-ipv6.sh
```

This updates the active BPXPRM member with IPv6-related network definitions if needed.

The script explicitly warns:

```text
WARNING: !!!!! READ MESSAGE ^^^^ YOU MAY NEED TO RE IPL YOUR Z/OS !!!!!
```

An IPL may be required before IPv6 support is active.

---

## 23. Main Datasets and Files Modified

The script may modify or create the following USS paths:

```text
/usr/local/sandboxes
/usr/local/sandboxes/tools
/usr/local/sandboxes/tools/zconfig
/tmp/taz_tools
/tmp/install-taz-driver.*.jcl
/tmp/EQAPPLAY*
/tmp/proclib-member.*.txt
/tmp/ifaprd00-*.txt
/tmp/ifaprd00-*.ebcdic
```

The script may modify these MVS datasets or members:

```text
SYS1.PROCLIB(EQAPPLAY)
SYS1.PROCLIB(EQAPROF)
SYS1.PROCLIB(DBGMGR)
SYS1.PARMLIB(PROGxx)
SYS1.PARMLIB(IFAPRD00)
SYS1.PARMLIB(BPXPRMxx) through enable-ipv6.sh
```

The script may also create or modify page datasets through `add-pageset.sh`.

---

## 24. External Dependencies

The script expects the following commands and tools to be available:

```text
sh
bash
curl
jar
tar
pax
sed
awk
grep
iconv
cp
rm
mkdir
ln
chmod
find
python3
pip3
tsocmd
opercmd
jsub
jls
pjdd
dls
dcp
dcat
chtag
extattr
```

It also expects:

```text
ZOAU_HOME
/global/opt/pyenv/gdp/bin/activate
SYS1.PARMLIB
SYS1.PROCLIB
EQAW.VHR0M0.PTF.* datasets
jcl/install-taz-driver.jcl
```

---

## 25. Security and Authority Requirements

The user running the script likely needs authority to:

- Allocate and mount zFS aggregates.
- Update OMVS attributes for `IBMUSER`.
- Update RACF or TSO user attributes.
- Update `SYS1.PROCLIB`.
- Update `SYS1.PARMLIB`.
- Submit JCL.
- Add APF-authorized datasets.
- Reprocess PROG and PROD members.
- Start and stop system procedures.
- Update BPXPRM through DSFS.

The Nexus credential is passed directly on the command line as `user:password`. This may expose the credential through command history or process listings depending on the environment.

---

## 26. Idempotency Notes

Some parts of the script are designed to be rerunnable:

- Existing download files are skipped.
- Existing APF entries are checked before appending.
- Existing IFAPRD00 product entries are checked before appending.
- Some services are stopped and started with errors ignored.
- zFS creation is delegated to `mkzfs.sh`, which is intended to be idempotent.

Other parts are destructive or not fully idempotent:

- `/usr/local/sandboxes/tools` is deleted and recreated.
- `mkdir zrb` may fail if the directory already exists.
- Some procedure replacements are direct overwrites.
- Tool extraction may overwrite or conflict with existing files.
- The extra page set loop may perform repeated system changes.

---

## 27. Potential Issues to Review

The following items should be reviewed before production use:

### Uninitialized variables

The script references:

```sh
PAGES_SETS
FAILED
```

These variables are not initialized in the visible script.

### Destructive directory cleanup

The script runs:

```sh
rm -rf /usr/local/sandboxes/tools
```

This removes all existing tool content.

### Command-line password exposure

The Nexus credential is passed as a command-line argument.

### Manual actions still required

The script prints some LNKLST, APF, IMS, and CICS updates but does not perform them.

### IPL requirement

Some changes may not fully take effect until IPL, especially IPv6 and some persistent system configuration changes.

### Hard-coded environment values

The script contains hard-coded values such as:

```text
IBMUSER
EQAW.VHR0M0.PTF
IDZ.V17R0M0
SYS1.PROCLIB
SYS1.PARMLIB
/global/opt/pyenv/gdp
zdevops-demo1.fyre.ibm.com
```

These should be validated before running in a different environment.

---

## 28. Summary

`install-tools.sh` is a broad automation script for preparing a z/OS sandbox and installing tooling around Java, Gradle, Wazi Deploy, ZConfig, CICS Resource Builder, TAZ, and IBM z/OS Debugger.

It performs both USS-level setup and system-level z/OS configuration. It is useful for repeatable lab provisioning, but it should be reviewed carefully before use in shared or production-like systems because it updates core configuration members and may require an IPL.
