#!/usr/bin/env bash
# Audit the port: is the tree consistent, and which features does it actually
# complete? Reads only files here (and, with --image, one downloaded artifact);
# it never touches the phone or the network.
#
#   tools/audit-features.sh                     # the source tree
#   tools/audit-features.sh --image <x6525-rom> # also the built artifact
#
# Two kinds of answer:
#   * "BROKEN" - something the ROM builds from is inconsistent (a stale patch
#     copy, a wrong checksum, a checksum line pasted into a variable, a DTB
#     that is not built). Exit status 1.
#   * per feature: COMPLETE in the tree, PARTIAL (something is missing; the
#     missing pieces are listed), or known-missing (documented as not ported).
# Nothing here is evidence that the hardware behaves - see the note at the end.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KPKG=$ROOT/pmaports/device/testing/linux-postmarketos-unisoc-ums9230
CFG=$KPKG/config-postmarketos-unisoc-ums9230.aarch64
DPKG=$ROOT/pmaports/device/testing/device-infinix-x6525
UPKG=$ROOT/pmaports/device/testing/u-boot-infinix-x6525
FWPKG=$ROOT/pmaports/device/testing/firmware-infinix-x6525
DTS=$ROOT/dts/ums9230-infinix-x6525.dts
IMAGE=
while [ $# -gt 0 ]; do
	case "$1" in
	--image)   IMAGE=${2:?--image needs the extracted x6525-rom directory}; shift 2 ;;
	-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

broken=0
ok()   { printf '    ok        %s\n' "$*"; }
bad()  { printf '    BROKEN    %s\n' "$*"; broken=1; }

# --- shell helpers --------------------------------------------------------
# An APKBUILD is a shell script: ask the shell for its variables, the way
# build.yml does, rather than scraping them out with sed.
# (-u off: APKBUILDs assign from variables like $srcdir that only exist at
# build time; with -u the source would abort on them)
var() { ( set +u; cd "$(dirname "$1")" && . ./APKBUILD &&
	eval "printf '%s\n' \"\${$2:-}\"" ); }
cfg() { grep -qE "^CONFIG_$1=(y|m)$" "$2"; }          # cfg <SYM> <config>
dt()  { grep -qF -- "$1" "$DTS"; }
listed() { var "$1/APKBUILD" "${2:-source}" | tr -s '[:space:]' '\n' | grep -qx -- "$3"; }

# --- 1. package integrity -------------------------------------------------
echo "== package integrity =="
for d in "$ROOT"/pmaports/device/testing/*/; do
	P=${d}APKBUILD
	name=$(basename "$d")
	[ -f "$P" ] || { bad "$name: no APKBUILD"; continue; }
	before=$broken

	# every local source= entry exists and matches its sha512sums entry
	for f in $(var "$P" source); do
		case "$f" in *'::'*) continue ;; esac   # a URL, not a local file
		[ -e "$d$f" ] || { bad "$name: source= names a missing file: $f"; continue; }
		sum=$(sha512sum "$d$f" | cut -d' ' -f1)
		var "$P" sha512sums | grep -qE "^$sum  $f$" ||
			bad "$name: sha512 does not match $f"
	done

	# no checksum line or patch filename pasted into a dependency list
	# (that once made pmbootstrap read a patch as a package name)
	for v in depends makedepends options; do
		stray=$(var "$P" "$v" | tr -s '[:space:]' '\n' | grep -E '^[0-9a-f]{128}$|\.patch$' || true)
		[ -z "$stray" ] || bad "$name: $v carries: $(echo $stray)"
	done
	stray=$(var "$P" source | tr -s '[:space:]' '\n' | grep -E '^[0-9a-f]{128}$' || true)
	[ -z "$stray" ] || bad "$name: source carries a checksum line"

	# the kernel package's copies of the submission series must be current
	if [ "$name" = "$(basename "$KPKG")" ]; then
		for p in "$ROOT"/patches/upstream/0*.patch; do
			b=$(basename "$p")
			listed "$KPKG" source "$b" || { bad "$name: $b is not in source="; continue; }
			cmp -s "$p" "$KPKG/$b" || bad "$name: $b differs from patches/upstream"
		done
		# the dtb-y entry lives in patch 0003, and the ROM's kernel package
		# installs DTBs - without it the image build fails in boot-deploy
		grep -q "ums9230-infinix-x6525.dtb" "$ROOT"/patches/upstream/0003-*.patch ||
			bad "$name: patch 0003 has no dtb-y entry for this board"
	fi
	[ "$broken" = "$before" ] && ok "$name"
done

# --- 2. feature completeness ---------------------------------------------
# A feature is COMPLETE when every piece the tree promises is present; PARTIAL
# lists what is missing; the last group is missing by design and says why.
state=ok; missing=
feature() { state=ok; missing=; printf '  %s\n' "$1"; }
need() { # need <what> <predicate...>
	local label=$1
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$label"
	else
		[ "$state" = ok ] && state=partial
		missing="$missing; $label"
		printf '    missing   %s\n' "$label"
	fi
}
finish() {
	case "$state" in
	ok)      printf '    => COMPLETE\n' ;;
	partial) printf '    => PARTIAL (missing:%s)\n' "$missing" ;;
	esac
}

echo
echo "== features in the tree =="

feature "storage: root filesystem and the eMMC"
need "sdio0 (microSD) enabled in the DTS"        dt '&sdio0'
need "sdio3 (eMMC) enabled in the DTS"           dt '&sdio3'
need "CONFIG_MMC_SDHCI_SPRD=y"                   cfg MMC_SDHCI_SPRD "$CFG"
need "CONFIG_MMC_BLOCK=y"                        cfg MMC_BLOCK "$CFG"
need "CONFIG_EXT4_FS=y"                          cfg EXT4_FS "$CFG"
need "deviceinfo flashes the kernel to boot_a"   grep -q 'partition_kernel="boot_a"' "$DPKG/deviceinfo"
finish

feature "serial console (ttyS1)"
need "CONFIG_SERIAL_SPRD=y"                      cfg SERIAL_SPRD "$CFG"
need "console=ttyS1 on the kernel command line"  grep -q 'console=ttyS1' "$DPKG/kernel-cmdline.conf"
need "a getty is offered on ttyS1"               grep -q 'deviceinfo_getty="ttyS1' "$DPKG/deviceinfo"
finish

feature "display (TD4160 HX panel)"
need "CONFIG_DRM_SPRD=y"                         cfg DRM_SPRD "$CFG"
need "CONFIG_DRM_PANEL_TD4160_HX=y"              cfg DRM_PANEL_TD4160_HX "$CFG"
need "fbdev console (DRM_FBDEV_EMULATION)"       cfg DRM_FBDEV_EMULATION "$CFG"
need "fbdev console (FRAMEBUFFER_CONSOLE)"       cfg FRAMEBUFFER_CONSOLE "$CFG"
need "panel node in the DTS"                     dt 'infinix,td4160-hx-panel'
need "drivers/panel-td4160-hx.c"                 test -f "$ROOT/drivers/panel-td4160-hx.c"
finish

feature "touchscreen (OmniVision TCM on SPI3)"
need "touch node in the DTS"                     dt 'omnivision,tcm-spi'
need "interrupt on eic_async 16, level-low"      grep -q 'eic_async 16 IRQ_TYPE_LEVEL_LOW' "$DTS"
need "CONFIG_TOUCHSCREEN_OVT_TCM_SPI=m"          cfg TOUCHSCREEN_OVT_TCM_SPI "$CFG"
need "drivers/ovt-tcm-spi.c"                     test -f "$ROOT/drivers/ovt-tcm-spi.c"
need "the driver ships in the series"            grep -q 'ovt-tcm-spi' "$ROOT"/patches/upstream/0006-*.patch
need "module in the initramfs"                   grep -qx 'ovt-tcm-spi' "$DPKG/modules-initfs"
need "HDL firmware in firmware/"                 test -f "$ROOT/firmware/hdl_firmware_01.img"
need "the firmware package is a dependency"      sh -c ". '$DPKG/APKBUILD'; printf '%s\n' \"\$depends\" | grep -q firmware-infinix-x6525"
finish

feature "framebuffer keyboard (buffyboard)"
# postmarketos-ui-buffyboard ships the service (systemd unit or OpenRC script)
# and enables it; ui = console installs only the binary. Its APKBUILD has
# pmb:default-openrc, so rom.yml must pin service_manager or the UI choice
# would also change the image's init system.
need "rom.yml selects the buffyboard UI"         grep -q '^ *ui = buffyboard' "$ROOT/.github/workflows/rom.yml"
need "rom.yml pins the service manager"          grep -q '^ *service_manager = systemd' "$ROOT/.github/workflows/rom.yml"
need "CONFIG_INPUT_UINPUT=y (key injection)"     cfg INPUT_UINPUT "$CFG"
need "CONFIG_FRAMEBUFFER_CONSOLE=y"              cfg FRAMEBUFFER_CONSOLE "$CFG"
need "simple-framebuffer node in the DTS"        dt 'simple-framebuffer'
finish

feature "Wi-Fi (Unisoc WCN, mainline sc23xx)"
need "CONFIG_WLAN_VENDOR_UNISOC=y"               cfg WLAN_VENDOR_UNISOC "$CFG"
need "CONFIG_SC23XX_CORE=m"                      cfg SC23XX_CORE "$CFG"
need "CONFIG_SC23XX_SIPC=m"                      cfg SC23XX_SIPC "$CFG"
need "CONFIG_SPRD_WCN_REMOTEPROC=m"              cfg SPRD_WCN_REMOTEPROC "$CFG"
need "the wcn node is enabled in the DTS"        grep -q '&wcn {' "$DTS"
need "the firmware package is a dependency"      sh -c ". '$DPKG/APKBUILD'; printf '%s\n' \"\$depends\" | grep -q firmware-infinix-x6525"
need "wcnmodem.bin is packaged"                  grep -q 'sprd/wcnmodem.bin' "$FWPKG/APKBUILD"
need "wifi_board_config.bin is packaged"         grep -q 'sprd/wifi_board_config.bin' "$FWPKG/APKBUILD"
need "the modules are loaded at boot"            grep -q 'sc23xx_wlan_sipc' "$DPKG/APKBUILD"
finish

feature "USB networking (the login path)"
need "CONFIG_USB_MUSB_SPRD=y"                    cfg USB_MUSB_SPRD "$CFG"
need "CONFIG_TYPEC_SC27XX_PD=y (role switch)"    cfg TYPEC_SC27XX_PD "$CFG"
need "CONFIG_USB_CONFIGFS=m"                     cfg USB_CONFIGFS "$CFG"
need "CONFIG_USB_CONFIGFS_NCM=y"                 cfg USB_CONFIGFS_NCM "$CFG"
need "CONFIG_USB_LIBCOMPOSITE=m"                 cfg USB_LIBCOMPOSITE "$CFG"
need "libcomposite in the initramfs"             grep -qx 'libcomposite' "$DPKG/modules-initfs"
need "u_ether in the initramfs"                  grep -qx 'u_ether' "$DPKG/modules-initfs"
need "usb_f_ncm in the initramfs"                grep -qx 'usb_f_ncm' "$DPKG/modules-initfs"
need "NCM function pinned in deviceinfo"         grep -q 'usb_network_function="ncm.usb0"' "$DPKG/deviceinfo"
finish

feature "charging and the battery gauge"
need "CONFIG_CHARGER_BQ2415X=m"                  cfg CHARGER_BQ2415X "$CFG"
need "CONFIG_CHARGER_EXTCON_DETECT=m"            cfg CHARGER_EXTCON_DETECT "$CFG"
need "charger node (ti,bq24158 at i2c3 0x6a)"    dt 'ti,bq24158'
need "usb-charger-detect node"                   dt 'linux,extcon-charger-detect'
need "CONFIG_FUEL_GAUGE_SC27XX=m"                cfg FUEL_GAUGE_SC27XX "$CFG"
need "fuel gauge node with power-supplies"       grep -q 'power-supplies = <&charger>' "$DTS"
finish

feature "keys, RTC, watchdog and pstore"
need "gpio-keys nodes"                           dt 'gpio-keys'
need "volume-up on the PMIC EIC"                 grep -q 'pmic_eic 4 GPIO_ACTIVE_HIGH' "$DTS"
need "CONFIG_RTC_DRV_SC27XX=y"                   cfg RTC_DRV_SC27XX "$CFG"
need "CONFIG_SPRD_WATCHDOG=y"                    cfg SPRD_WATCHDOG "$CFG"
need "CONFIG_PSTORE_RAM=y"                       cfg PSTORE_RAM "$CFG"
need "ramoops reservation in the DTS"            dt 'ramoops'
finish

feature "boot chain (U-Boot in boot_a, extlinux)"
need "U-Boot board defconfig"                    test -f "$ROOT/uboot/configs/infinix-x6525_defconfig"
need "U-Boot board device tree"                  test -f "$ROOT/uboot/dts/ums9230-infinix-x6525.dts"
need "deviceinfo builds the U-Boot boot image"   grep -q 'generate_bootimg="true"' "$DPKG/deviceinfo"
need "deviceinfo builds the extlinux config"     grep -q 'generate_extlinux_config="true"' "$DPKG/deviceinfo"
need "the u-boot package installs u-boot.bin"    grep -q 'share/u-boot/infinix-x6525' "$UPKG/APKBUILD"
finish

echo
echo "== missing by design (documented, not defects) =="
printf '  known-missing  Bluetooth: btsprdsipc and the WCN firmware are in the image, but nothing\n'
printf '                 has exercised the Bluetooth stack on this hardware yet\n'
printf '  known-missing  cameras: no mainline driver work started\n'
printf '  known-missing  USB source role: mainline bq2415x exposes no VBUS regulator for the boost\n'
printf '  known-missing  BC1.2 detection: charging is limited to 500 mA until the SC2730 has a driver\n'

# --- 3. the built artifact (optional) -------------------------------------
if [ -n "$IMAGE" ]; then
	echo
	echo "== built artifact: $IMAGE =="
	[ -d "$IMAGE" ] || { bad "no such directory: $IMAGE"; }
	IMGDIR=$(cd "$IMAGE" 2>/dev/null && pwd) || exit 1
	cd "$IMGDIR" || exit 1
	for f in boot.img initramfs vmlinuz; do
		[ -e "$f" ] || bad "the artifact has no $f"
	done
	# the disk image is what the workflow uploads, but the two filesystems
	# are enough to audit; a copy saved without the 1.3 GB disk image (to
	# fit on a small host) must not count as broken
	if [ ! -e infinix-x6525.img ] &&
	   { [ ! -e pmos-boot-fs.img ] || [ ! -e pmos-root-fs.img ]; }; then
		bad "the artifact has neither infinix-x6525.img nor both split filesystems"
	fi
	if [ -f boot.img ]; then
		python3 -I "$ROOT/tools/check-boot-img.py" boot.img >/dev/null 2>&1 &&
			ok "boot.img passes check-boot-img.py" || bad "boot.img fails check-boot-img.py"
	fi

	TMP=$(mktemp -d) || exit 1
	trap 'rm -rf "$TMP"' EXIT
	# the two filesystems, by label - no loop device needed. Newer rom.yml
	# uploads them split already; use those instead of copying the 1.3 GB disk.
	if [ -f pmos-boot-fs.img ] && [ -f pmos-root-fs.img ]; then
		cp pmos-boot-fs.img "$TMP/boot.img"
		cp pmos-root-fs.img "$TMP/root.img"
		ok "the artifact already carries pmOS_boot and pmOS_root"
	elif python3 -I "$ROOT/tools/split-disk-image.py" infinix-x6525.img \
			"$TMP/boot.img" "$TMP/root.img" >/dev/null 2>&1; then
		ok "the disk image splits into pmOS_boot and pmOS_root"
	else
		bad "could not split infinix-x6525.img into pmOS_boot and pmOS_root"
	fi
	if [ -s "$TMP/boot.img" ]; then

		# the boot filesystem must hold what extlinux asks for
		debugfs -R "cat /extlinux/extlinux.conf" "$TMP/boot.img" >"$TMP/extlinux.conf" 2>/dev/null
		for f in /vmlinuz /initramfs /ums9230-infinix-x6525.dtb; do
			grep -q "$f" "$TMP/extlinux.conf" ||
				bad "extlinux does not name $f"
			debugfs -R "stat $f" "$TMP/boot.img" 2>/dev/null | grep -q . ||
				bad "the boot filesystem has no $f"
		done
		grep -q 'loglevel=7' "$TMP/extlinux.conf" || bad "the cmdline has no loglevel=7"
		grep -q 'console=ttyS1' "$TMP/extlinux.conf" || bad "the cmdline has no console=ttyS1"
		ok "the boot filesystem holds what extlinux names, with loglevel and the UART console"

		# the effective kernel config is the one in the boot filesystem
		debugfs -R "dump /config $TMP/config" "$TMP/boot.img" >/dev/null 2>&1
		if [ -s "$TMP/config" ]; then
			symfail=0
			for sym in MMC_SDHCI_SPRD EXT4_FS SERIAL_SPRD DRM_SPRD DRM_PANEL_TD4160_HX \
				   DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE TOUCHSCREEN_OVT_TCM_SPI \
				   CHARGER_BQ2415X CHARGER_EXTCON_DETECT USB_MUSB_SPRD TYPEC_SC27XX_PD \
				   USB_CONFIGFS USB_CONFIGFS_NCM USB_LIBCOMPOSITE PSTORE_RAM; do
				cfg "$sym" "$TMP/config" || { bad "the built config lacks CONFIG_$sym=y|m"; symfail=1; }
			done
			[ "$symfail" = 0 ] && ok "the built config has every symbol the features need"
			# The required symbols are checked above. What is left in a diff
			# against the package's config should only be build-toolchain
			# lines (olddefconfig with the runner's clang); anything else is
			# worth a look but is not, by itself, a broken feature.
			symdiff=$(diff "$CFG" "$TMP/config" | grep -E '^[<>] CONFIG_' |
				grep -vE '^[<>] CONFIG_(CC_|AS_|LD_|LLD_|CLANG|GCC|LOCALVERSION|WARN_|.*_VERSION)' |
				head -5)
			[ -z "$symdiff" ] &&
				ok "the built config agrees with the package's outside toolchain lines" ||
				printf '    note      other config differences: %s\n' "$(echo $symdiff)"
		else
			bad "the boot filesystem has no /config"
		fi
	fi

	# the login the README documents: user <rom.yml's --password>, root locked
	if [ -s "$TMP/root.img" ]; then
		pw=$(grep -oE -- '--password [^ ;"]+' "$ROOT/.github/workflows/rom.yml" |
			head -1 | cut -d' ' -f2)
		debugfs -R "dump /etc/shadow $TMP/shadow" "$TMP/root.img" >/dev/null 2>&1
		if [ -s "$TMP/shadow" ]; then
			rootf=$(awk -F: '$1=="root"{print $2}' "$TMP/shadow")
			userf=$(awk -F: '$1=="user"{print $2}' "$TMP/shadow")
			case "$rootf" in
			'!'*|'*'*) ok "root is locked" ;;
			*)         bad "root is not locked" ;;
			esac
			case "$userf" in
			'$6$'*)
				salt=$(echo "$userf" | cut -d'$' -f3)
				if command -v openssl >/dev/null 2>&1 && [ -n "$pw" ] &&
				   [ "$(openssl passwd -6 -salt "$salt" "$pw" 2>/dev/null)" = "$userf" ]; then
					ok "user's password is rom.yml's --password ($pw)"
				else
					bad "user's password is not rom.yml's --password"
				fi ;;
			'') bad "user has no password" ;;
			*)  printf '    note      user has a password (%s-crypt); not checked offline\n' \
					"$(echo "$userf" | cut -d'$' -f2)" ;;
			esac
		else
			bad "the root filesystem has no /etc/shadow"
		fi
	fi

	# the on-screen keyboard: its service must be installed (ui = buffyboard)
	# and enabled. Which service depends on the image's init system: systemd
	# (the unit, enabled by postmarketos-base's 90-base.preset at build time)
	# or OpenRC (the init script, added to the default runlevel by the UI's
	# openrc subpackage post-install).
	if [ -s "$TMP/root.img" ]; then
		if debugfs -R "stat /usr/lib/systemd/systemd" "$TMP/root.img" 2>/dev/null | grep -q .; then
			init=systemd
		elif debugfs -R "stat /sbin/openrc" "$TMP/root.img" 2>/dev/null | grep -q .; then
			init=openrc
		else
			init=unknown
		fi
		debugfs -R "stat /usr/bin/buffyboard" "$TMP/root.img" 2>/dev/null | grep -q . &&
			ok "the buffyboard binary is installed" ||
			bad "the buffyboard binary is not installed"
		case $init in
		systemd)
			debugfs -R "stat /usr/lib/systemd/system/buffyboard.service" \
				"$TMP/root.img" 2>/dev/null | grep -q . &&
				ok "the systemd image installs buffyboard.service" ||
				bad "no buffyboard.service in the systemd root filesystem (ui is not buffyboard)"
			debugfs -R "stat /etc/systemd/system/multi-user.target.wants/buffyboard.service" \
				"$TMP/root.img" 2>/dev/null | grep -q . &&
				ok "buffyboard.service is enabled at boot" ||
				bad "buffyboard.service is not enabled at boot" ;;
		openrc)
			debugfs -R "stat /etc/init.d/buffyboard" "$TMP/root.img" 2>/dev/null | grep -q . &&
				ok "the OpenRC image installs the buffyboard init script" ||
				bad "no /etc/init.d/buffyboard in the OpenRC root filesystem (ui is not buffyboard)"
			debugfs -R "stat /etc/runlevels/default/buffyboard" "$TMP/root.img" 2>/dev/null | grep -q . &&
				ok "buffyboard is in the default runlevel" ||
				bad "buffyboard is not in the default runlevel" ;;
		*)
			bad "cannot tell the root filesystem's init system" ;;
		esac
	fi

	# Wi-Fi: the firmware and the module autoload live in the rootfs
	if [ -s "$TMP/root.img" ]; then
		for f in /lib/firmware/sprd/wcnmodem.bin \
			 /lib/firmware/sprd/wifi_board_config.bin \
			 /usr/lib/modules-load.d/x6525-wifi.conf; do
			debugfs -R "stat $f" "$TMP/root.img" 2>/dev/null | grep -q . &&
				ok "the root filesystem has $f" ||
				bad "the root filesystem has no $f"
		done
	fi

	# every module the initramfs is supposed to carry is in it
	mkdir -p "$TMP/initramfs"
	if ( cd "$TMP/initramfs" &&
	     zstd -dc "$IMGDIR/initramfs" 2>/dev/null |
	     cpio -idm --quiet --no-absolute-filenames 2>/dev/null ); then
		for m in $(grep -v '^#' "$DPKG/modules-initfs"); do
			[ -n "$m" ] || continue
			find "$TMP/initramfs" -name "$m.ko*" | grep -q . ||
				bad "the initramfs does not carry $m"
		done
		ok "the initramfs carries the modules modules-initfs names"
		find "$TMP/initramfs" -path '*firmware*' -name 'hdl_firmware_01.img' | grep -q . &&
			ok "the touch firmware is in the initramfs" ||
			bad "the touch firmware is not in the initramfs"
	else
		bad "could not unpack the initramfs (zstd/cpio)"
	fi
fi

echo
if [ "$broken" = 0 ]; then
	echo "result: no broken package or artifact checks"
else
	echo "result: BROKEN - see the lines above"
fi
cat <<'NOTE'

Not checked here, because only the hardware can settle it: the bootloader
accepting the boot image, the microSD rails before U-Boot runs, the panel reset
polarity and brightness curve, the touch firmware download, the SC27xx USB role
switch, and the eMMC/SD phy tuning. FIRST_BOOT.md lists them in the order they
will matter.
NOTE
exit "$broken"
