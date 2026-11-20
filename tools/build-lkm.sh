#!/usr/bin/env bash
# Build isolated ARM64 root/SUSFS modules with the repository's pinned DDK.
set -Eeuo pipefail
# shellcheck source=build-common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/build-common.sh"
milksu_freeze "$@"
kmi="${1:-android14-6.1}"
mode="${2:-both}"
case "$kmi" in
    android12-5.10|android13-5.10|android13-5.15|android14-5.15|android14-6.1|android15-6.6|android16-6.12|android17-6.18) ;;
    *) milksu_die "Unknown KMI: $kmi" ;;
esac
case "$mode" in root|susfs|both|baseline) ;; *) milksu_die "Mode must be root, susfs, both, or baseline." ;; esac
milksu_log "lkm-$kmi-$mode"
milksu_space
milksu_heavy_lock
metadata="$MILKSU_OUT/private/certificate.json"
[[ -f "$metadata" ]] || bash "$MILKSU_ROOT/tools/build-signing.sh"
read -r package cert_size cert_hash < <(python3 - "$metadata" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c["KSU_PACKAGE_NAME"], c["KSU_EXPECTED_SIZE"], c["KSU_EXPECTED_HASH"])
PY
)
image="ghcr.io/ylarod/ddk-min:$kmi-$MILKSU_DDK_RELEASE"
if ! docker image inspect "$image" >/dev/null 2>&1; then
    bash "$MILKSU_ROOT/tools/bootstrap-milksu.sh" ddk "$kmi"
fi
source_root="${MILKSU_SOURCE_ROOT:-$MILKSU_ROOT}"
if [[ -z "${MILKSU_SOURCE_ROOT:-}" && -f "$MILKSU_CACHE/sources/kernel-source-ready/.milksu-kernel-ready" ]]; then
    source_root="$MILKSU_CACHE/sources/kernel-source-ready"
fi
destination="$MILKSU_OUT/aarch64"
if [[ "$mode" == baseline ]]; then
    source_root="$MILKSU_CACHE/sources/baseline-$(git -C "$MILKSU_ROOT" rev-parse --short=12 HEAD)"
    [[ -d "$source_root/.git" ]] || milksu_die "Run build-rust.sh fetch to create the baseline snapshot first."
    destination="$MILKSU_OUT/baseline/aarch64"
fi
work="$MILKSU_CACHE/build/lkm/$mode/$kmi"
mkdir -p "$work/kernel" "$work/uapi" "$destination"
exec {build_lock}>"$MILKSU_CACHE/build/lkm/$mode-$kmi.lock"
flock "$build_lock"
milksu_run rsync -a --delete --exclude='*.o' --exclude='*.ko' --exclude='*.cmd' \
    --exclude='*.mod' --exclude='*.mod.c' --exclude='*.symversions' --exclude=Module.symvers \
    --exclude=modules.order --exclude=check_symbol --exclude=out \
    "$source_root/kernel/" "$work/kernel/"
milksu_run rsync -a --delete "$source_root/uapi/" "$work/uapi/"
# Ship the vermagic patcher alongside the sources so the container can call it
# after linking (see the "patch-vermagic.py" step below).
cp "$MILKSU_ROOT/tools/patch-vermagic.py" "$work/patch-vermagic.py"
if [[ "$mode" != baseline ]]; then
    [[ -f "$source_root/version.properties" ]] ||
        milksu_die "Kernel source snapshot has no shared release version; freeze it again."
    cp "$source_root/version.properties" "$work/version.properties"
fi
(
    cd "$source_root"
    find kernel uapi -type f \( -name '*.c' -o -name '*.h' -o -name '*.S' -o -name Kbuild -o -name Makefile \) \
        ! -name '*.mod.c' -print0 | sort -z | xargs -0 sha256sum
    if [[ -f version.properties ]]; then sha256sum version.properties; fi
) >"$work/source.sha256"
gitdir="$(git -C "$MILKSU_ROOT" rev-parse --absolute-git-dir)"
# shellcheck disable=SC2016
container_script='
set -Eeuo pipefail
git config --global --add safe.directory /source
cd /source/kernel
printf "DDK KDIR=%s ARCH=%s\n" "$KDIR" "$ARCH"

# --- vermagic override -------------------------------------------------
# A vendor kernel reports a custom release string and/or a custom
# MODULE_ARCH_VERMAGIC (for example "vivo aarch64"). The stock DDK carries
# the generic values, so insmod on such a device rejects the module with a
# vermagic mismatch. Symbol CRCs are not a constraint here: these modules
# resolve kernel symbols at runtime through kallsyms_lookup_name and ship an
# empty __versions section, so overriding the two vermagic strings is enough.
if [[ -n "${MILKSU_KMOD_UTS_RELEASE:-}" ]]; then
    # modpost takes vermagic from UTS_RELEASE, which lives in
    # include/generated/utsrelease.h. include/config/kernel.release only caches
    # the output of `make kernelrelease`, so writing it alone changes nothing.
    printf "%s" "$MILKSU_KMOD_UTS_RELEASE" > "$KDIR/include/config/kernel.release"
    uts_h="$KDIR/include/generated/utsrelease.h"
    if [[ -f "$uts_h" ]]; then
        sed -i "s|^#define UTS_RELEASE .*|#define UTS_RELEASE \"$MILKSU_KMOD_UTS_RELEASE\"|" "$uts_h"
        printf "vermagic: UTS_RELEASE    -> %s\n" "$MILKSU_KMOD_UTS_RELEASE"
    else
        printf "WARN: %s missing, cannot override UTS_RELEASE\n" "$uts_h"
    fi
fi
if [[ -n "${MILKSU_KMOD_ARCH_VERMAGIC:-}" ]]; then
    # The DDK ships a trimmed KDIR whose include/linux/vermagic.h is absent, so
    # MODULE_ARCH_VERMAGIC cannot be patched in place and modpost keeps the
    # generic arch string it was built with. Recreate the header with the
    # vendor value and let make rebuild modpost against it.
    kmod_h="$KDIR/arch/arm64/include/asm/module.h"
    vm_h="$KDIR/include/linux/vermagic.h"
    if [[ -f "$kmod_h" ]] && grep -q "MODULE_ARCH_VERMAGIC" "$kmod_h"; then
        sed -i "s|.*MODULE_ARCH_VERMAGIC.*|#define MODULE_ARCH_VERMAGIC \"$MILKSU_KMOD_ARCH_VERMAGIC\"|" "$kmod_h"
        printf "vermagic: asm/module.h   -> %s\n" "$MILKSU_KMOD_ARCH_VERMAGIC"
    fi
    if [[ ! -f "$vm_h" ]]; then
        mkdir -p "$KDIR/include/linux"
        printf "%s\n" \
            "#ifndef _LINUX_VERMAGIC_H" \
            "#define _LINUX_VERMAGIC_H" \
            "#include <generated/utsrelease.h>" \
            "#ifdef CONFIG_SMP" \
            "#define MODULE_VERMAGIC_SMP \"SMP \"" \
            "#else" \
            "#define MODULE_VERMAGIC_SMP \"\"" \
            "#endif" \
            "#if defined(CONFIG_PREEMPT_BUILD) || defined(CONFIG_PREEMPT)" \
            "#define MODULE_VERMAGIC_PREEMPT \"preempt \"" \
            "#elif defined(CONFIG_PREEMPT_RT)" \
            "#define MODULE_VERMAGIC_PREEMPT \"preempt_rt \"" \
            "#else" \
            "#define MODULE_VERMAGIC_PREEMPT \"\"" \
            "#endif" \
            "#ifdef CONFIG_MODULE_UNLOAD" \
            "#define MODULE_VERMAGIC_MODULE_UNLOAD \"mod_unload \"" \
            "#else" \
            "#define MODULE_VERMAGIC_MODULE_UNLOAD \"\"" \
            "#endif" \
            "#ifdef CONFIG_MODVERSIONS" \
            "#define MODULE_VERMAGIC_MODVERSIONS \"modversions \"" \
            "#else" \
            "#define MODULE_VERMAGIC_MODVERSIONS \"\"" \
            "#endif" \
            "#define MODULE_ARCH_VERMAGIC \"$MILKSU_KMOD_ARCH_VERMAGIC\"" \
            "#define VERMAGIC_STRING UTS_RELEASE \" \" MODULE_VERMAGIC_SMP MODULE_VERMAGIC_PREEMPT MODULE_VERMAGIC_MODULE_UNLOAD MODULE_VERMAGIC_MODVERSIONS MODULE_ARCH_VERMAGIC" \
            "#endif" > "$vm_h"
        printf "vermagic: recreated %s\n" "$vm_h"
        make -C "$KDIR" scripts >/dev/null 2>&1 || printf "WARN: make scripts failed, modpost may stay generic\n"
    else
        sed -i "s|.*MODULE_ARCH_VERMAGIC.*|#define MODULE_ARCH_VERMAGIC \"$MILKSU_KMOD_ARCH_VERMAGIC\"|" "$vm_h"
    fi
    printf "vermagic: ARCH_VERMAGIC -> %s\n" "$MILKSU_KMOD_ARCH_VERMAGIC"
fi
# -----------------------------------------------------------------------

if [[ "$MILKSU_MODE" != susfs ]]; then
    make -C "$KDIR" M=/source/kernel ARCH=arm64 CONFIG_ARM64=y CONFIG_KSU=m clean
    CONFIG_KSU=m CC=clang make -j"$MILKSU_JOBS" \
        KSU_PACKAGE_NAME="$KSU_PACKAGE_NAME" KSU_EXPECTED_SIZE="$KSU_EXPECTED_SIZE" \
        KSU_EXPECTED_HASH="$KSU_EXPECTED_HASH"
    cp kernelsu.ko "/artifacts/${MILKSU_KMI}_kernelsu.ko"
    llvm-strip -d "/artifacts/${MILKSU_KMI}_kernelsu.ko"
    if [[ -n "${MILKSU_KMOD_UTS_RELEASE:-}" && -n "${MILKSU_KMOD_ARCH_VERMAGIC:-}" ]]; then
        tgt="/artifacts/${MILKSU_KMI}_kernelsu.ko"
        python3 /source/patch-vermagic.py "$tgt" "$tgt.patched" "$MILKSU_KMOD_ARCH_VERMAGIC" 2>&1 | sed "s/^/  /" || true
        [[ -s "$tgt.patched" ]] && mv "$tgt.patched" "$tgt"
    fi
    printf "built vermagic:\n"
    readelf -p .modinfo "/artifacts/${MILKSU_KMI}_kernelsu.ko" 2>/dev/null | grep vermagic || true
    readelf -h "/artifacts/${MILKSU_KMI}_kernelsu.ko" >/dev/null
fi
if [[ "$MILKSU_MODE" == both || "$MILKSU_MODE" == susfs ]]; then
    test -f susfs/Makefile
    extra_symbols=()
    if [[ -f /source/kernel/Module.symvers ]]; then
        extra_symbols=(KBUILD_EXTRA_SYMBOLS=/source/kernel/Module.symvers)
    fi
    if [[ "$MILKSU_KMI" == android17-6.18 ]]; then
        make -C "$KDIR" M=/source/kernel/susfs MO=/source/kernel/susfs \
            modules -j"$MILKSU_JOBS" CC=clang "${extra_symbols[@]}"
    else
        make -C "$KDIR" M=/source/kernel/susfs src=/source/kernel/susfs \
            modules -j"$MILKSU_JOBS" CC=clang "${extra_symbols[@]}"
    fi
    cp susfs/susfs_guard_lkm.ko "/artifacts/${MILKSU_KMI}_susfs_guard_lkm.ko"
    llvm-strip -d "/artifacts/${MILKSU_KMI}_susfs_guard_lkm.ko"
    if [[ -n "${MILKSU_KMOD_UTS_RELEASE:-}" && -n "${MILKSU_KMOD_ARCH_VERMAGIC:-}" ]]; then
        tgt="/artifacts/${MILKSU_KMI}_susfs_guard_lkm.ko"
        python3 /source/patch-vermagic.py "$tgt" "$tgt.patched" "$MILKSU_KMOD_ARCH_VERMAGIC" 2>&1 | sed "s/^/  /" || true
        [[ -s "$tgt.patched" ]] && mv "$tgt.patched" "$tgt"
    fi
    printf "built vermagic:\n"
    readelf -p .modinfo "/artifacts/${MILKSU_KMI}_susfs_guard_lkm.ko" 2>/dev/null | grep vermagic || true
    readelf -h "/artifacts/${MILKSU_KMI}_susfs_guard_lkm.ko" >/dev/null
fi
'
milksu_run docker run --rm --network host \
    --cpuset-cpus="0-$((MILKSU_JOBS - 1))" \
    --memory=1536m --memory-swap=2g --pids-limit=512 \
    --mount "type=bind,src=$work,dst=/source" \
    --mount "type=bind,src=$gitdir,dst=/source/.git,readonly" \
    --mount "type=bind,src=$destination,dst=/artifacts" \
    -e "MILKSU_MODE=$mode" -e "MILKSU_KMI=$kmi" -e "MILKSU_JOBS=$MILKSU_JOBS" \
    -e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" -e KBUILD_BUILD_USER=milksu -e KBUILD_BUILD_HOST=milksu \
    -e "KSU_PACKAGE_NAME=$package" -e "KSU_EXPECTED_SIZE=$cert_size" \
    -e "KSU_EXPECTED_HASH=$cert_hash" \
    -e "MILKSU_KMOD_UTS_RELEASE=${MILKSU_KMOD_UTS_RELEASE:-}" \
    -e "MILKSU_KMOD_ARCH_VERMAGIC=${MILKSU_KMOD_ARCH_VERMAGIC:-}" \
    "$image" bash -c "$container_script"
mkdir -p "$MILKSU_OUT/manifests"
cp "$work/source.sha256" "$MILKSU_OUT/manifests/lkm-$kmi-$mode-source.sha256"
python3 - "$destination" "$kmi" "$mode" "$metadata" "$image" "$MILKSU_OUT/manifests" "$work/version.properties" <<'PY'
import configparser, hashlib, json, pathlib, subprocess, sys
directory, kmi, mode, cert, image, manifests, version_file = sys.argv[1:]
artifacts = []
for path in sorted(pathlib.Path(directory).glob(f"{kmi}_*.ko")):
    data = path.read_bytes()
    artifacts.append({"file": str(path), "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
report = {
    "kmi": kmi, "mode": mode, "artifacts": artifacts,
    "signing": json.load(open(cert)),
    "ddk": json.loads(subprocess.check_output(["docker", "image", "inspect", image]))[0]["RepoDigests"],
    "root_rebuilt": mode in ("root", "both", "baseline"),
    "susfs_rebuilt": mode in ("susfs", "both"),
    "susfs_reused": mode == "root",
}
if mode != "baseline":
    version = configparser.ConfigParser(interpolation=None)
    version.read_string("[release]\n" + pathlib.Path(version_file).read_text())
    report["release"] = {
        "version_name": version["release"]["MILKSU_VERSION_NAME"],
        "version_code": version["release"].getint("MILKSU_VERSION_CODE"),
        "manifest_sha256": hashlib.sha256(pathlib.Path(version_file).read_bytes()).hexdigest(),
    }
path = pathlib.Path(manifests) / f"lkm-{kmi}-{mode}.json"
path.write_text(json.dumps(report, indent=2) + "\n")
if mode != "baseline":
    (pathlib.Path(manifests) / f"lkm-{kmi}.json").write_text(json.dumps(report, indent=2) + "\n")
    # The pair manifest always describes the actual current pair, including reused components.
    (pathlib.Path(manifests) / f"lkm-{kmi}-both.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"manifest": str(path), "artifacts": artifacts}, indent=2))
PY
milksu_space
