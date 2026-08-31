#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa"
srcfolder="mesa"

run_all(){
	echo -e "${green}====== Begin building TU V${BUILD_VERSION}! ======${nocolor}"
	check_deps
	prepare_workdir

	build_lib_for_android main
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps; do
		if command -v "$deps_chk" >/dev/null 2>&1 ; then
			echo -e "$green - $deps_chk found $nocolor"
		else
			echo -e "$red - $deps_chk not found, can't continue. $nocolor"
			deps_missing=1
		fi
	done

	if [ "$deps_missing" == "1" ]; then
		echo "Please install missing dependencies" && exit 1
	fi

	echo "Installing python Mako dependency..."
	pip install mako &> /dev/null || true
}

prepare_workdir(){
	echo "Preparing work directory..."
	mkdir -p "$workdir" && cd "$_"

	# DroidVM: build from the exact upstream commit recorded in mesa_hash.txt instead
	# of whatever mesa/main is right now -- the same checkout of this repo must always
	# produce the same driver. Bumping = updating mesa_hash.txt (upstream's
	# mesa-watcher moves it on every mesa/main commit, so a rebase onto upstream
	# A8xx bumps it for free). TURNIP_MESA_REF=main opts back into bleeding edge.
	mesa_ref="${TURNIP_MESA_REF:-$(cat "$workdir/../mesa_hash.txt")}"

	if [ "${SKIP_SOURCE_DOWNLOAD}" = "1" ]; then
		echo "Skipping NDK + Mesa download (reusing existing source)..."
		# Reset Mesa source to clean state before re-patching. clean -fd drops the
		# .rej/.orig droppings and patch-created files checkout cannot see -- stale
		# rejects would otherwise trip the reject gate below on every rebuild.
		if [ -d "$srcfolder/.git" ]; then
			echo "Resetting Mesa source tree..."
			git -C "$srcfolder" checkout .
			git -C "$srcfolder" clean -qfd
			cur=$(git -C "$srcfolder" rev-parse HEAD)
			if [ "$mesa_ref" != main ] && [ "$mesa_ref" != "$cur" ]; then
				echo -e "${red}Warning: mesa tree is at $cur but mesa_hash.txt wants $mesa_ref"
				echo -e "         (rebuilding what is checked out; delete turnip_workdir/mesa to re-pin)${nocolor}"
			fi
		fi
		return
	fi

	if [ -d "$ndkver" ]; then
		echo "Reusing extracted android-ndk..."
	else
		echo "Downloading android-ndk from google server..."
		curl -sL https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null

		echo "Extracting android-ndk..."
		unzip -q "$ndkver"-linux.zip &> /dev/null
	fi

	echo "Downloading mesa source at $mesa_ref..."
	git init -q $srcfolder
	git -C "$srcfolder" remote add origin "$mesasrc"
	git -C "$srcfolder" fetch --depth=1 origin "$mesa_ref"
	git -C "$srcfolder" checkout -q FETCH_HEAD
}

build_lib_for_android(){
	cd "$workdir/$srcfolder"
	echo "==== Building Mesa on $1 branch ===="

	# Apply optional patches if EXTRA_PATCH is set (colon-separated list, applied
	# in order, e.g. patches/a8xx_gen8.patch:patches/droidvm_kgsl.patch)
	if [ -n "$EXTRA_PATCH" ]; then
		IFS=':' read -ra PATCHES <<< "$EXTRA_PATCH"
		for PATCH_FILE in "${PATCHES[@]}"; do
			if ! [ -f "../../$PATCH_FILE" ]; then
				echo -e "${red}Patch $PATCH_FILE not found, aborting!${nocolor}"; exit 1
			fi
			echo "Applying patch series: $PATCH_FILE"
			patch -p1 -N --fuzz=4 < "../../$PATCH_FILE" || echo -e "${red}Warning: partial patch failures, continuing...${nocolor}"
		done
		# DroidVM: with mesa pinned to mesa_hash.txt every hunk must land -- a hunk
		# left in a .rej is a half-patched driver that still builds and looks fine.
		# PATCH_REJECTS_OK=1 restores the old tolerant behavior (unpinned mesa).
		if [ "${PATCH_REJECTS_OK:-0}" != "1" ]; then
			rejects=$(find . -name '*.rej')
			if [ -n "$rejects" ]; then
				echo -e "${red}Patch hunks were rejected:${nocolor}"
				echo "$rejects"
				exit 1
			fi
		fi
	fi

	# Apply optional Python scripts if EXTRA_SCRIPT is set (colon-separated list)
	# freedreno_devices.py: reset if patch left it with syntax errors, then re-apply cleanly
	if [ -n "$EXTRA_SCRIPT" ]; then
		if ! python3 -c "compile(open('src/freedreno/common/freedreno_devices.py').read(),'f','exec')" 2>/dev/null; then
			echo -e "${red}freedreno_devices.py has syntax errors after patching — resetting${nocolor}"
			git checkout -- src/freedreno/common/freedreno_devices.py
		fi
		IFS=':' read -ra SCRIPTS <<< "$EXTRA_SCRIPT"
		for SCRIPT in "${SCRIPTS[@]}"; do
			if [ -f "../../$SCRIPT" ]; then
				echo "Running script: $SCRIPT"
				python3 "../../$SCRIPT" || { echo -e "${red}Script $SCRIPT failed, aborting!${nocolor}"; exit 1; }
			fi
		done
	fi

	# Preventive fixes for NDK r29 compilation
	sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
	sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
	sed -i -E 's/([a-z_]+)->handle->/((const native_handle_t *)\1->handle)->/g' src/vulkan/runtime/vk_android.c || true

	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"
	export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"
	export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"

	GITHASH=$(git rev-parse --short HEAD)

	echo "Generating build files..."
	cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

	meson setup build-android-aarch64 \
		--cross-file "android-aarch64.txt" \
		--native-file "native.txt" \
		--prefix /tmp/turnip-$1 \
		-Dbuildtype=release \
		-Dstrip=true \
		-Dplatforms=android \
		-Dvideo-codecs= \
		-Dplatform-sdk-version="$sdkver" \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dplatform-sdk-version=36 \
		-Dandroid-libbacktrace=disabled \
		--reconfigure

	echo "Compiling build files..."
	ninja -C build-android-aarch64 install

	if ! [ -f /tmp/turnip-$1/lib/libvulkan_freedreno.so ]; then
		echo -e "${red}Build failed!${nocolor}" && exit 1
	fi

	echo "Making the archive..."
	cd /tmp/turnip-$1/lib

	_meta_name="${META_NAME:-Mesa Turnip v${BUILD_VERSION}-${GITHASH}}"
	_meta_desc="${META_DESC:-A6xx/A7xx Turnip driver from Mesa main (git ${GITHASH}). KGSL build. A8xx experimental.}"
	_zip_suffix="${BUILD_SUFFIX:+-${BUILD_SUFFIX}}"
	_zip_name="mesa-turnip-$1${_zip_suffix}-V${BUILD_VERSION}.zip"

	_mesa_vk_header="$workdir/$srcfolder/include/vulkan/vulkan_core.h"
	_vk_patch=$(grep '^#define VK_HEADER_VERSION ' "$_mesa_vk_header" | awk '{print $3}')
	_vk_minor=$(grep 'define TU_API_VERSION' "$workdir/$srcfolder/src/freedreno/vulkan/tu_device.cc" | grep -oP 'VK_MAKE_VERSION\(\s*[0-9]+,\s*\K[0-9]+')
	_driver_version="Vulkan 1.${_vk_minor}.${_vk_patch}"

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "${_meta_name}",
  "description": "${_meta_desc}",
  "author": "The412Banner",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "${_driver_version}",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
	zip -q "/tmp/${_zip_name}" libvulkan_freedreno.so meta.json
	cd - > /dev/null

	if ! [ -f "/tmp/${_zip_name}" ]; then
		echo -e "${red}Failed to pack the archive!${nocolor}"
	else
		cp "/tmp/${_zip_name}" "$workdir/"
		echo -e "${green}Build completed successfully! → ${_zip_name}${nocolor}"
	fi
}

run_all
