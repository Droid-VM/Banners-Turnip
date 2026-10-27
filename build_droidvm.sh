#!/bin/bash -e
# DroidVM host turnip build -- the entry point 5_prepare_turnip.sh in the DroidVM meta
# repo calls. gfxstream/venus (vk command proxy) executes the guest's Vulkan on this
# driver over kgsl on the host phone. Guest-side turnip (kgsl proxy / virtio native
# context) is a different build from Droid-VM/mesa and does not come from this repo.
#
# Recipe = the A8xx variant of .github/workflows/turnip_build_combined.yml (a8xx gen8
# stack on top of upstream mesa, pinned to mesa_hash.txt by build_turnip.sh) plus the
# DroidVM host patches. One .so covers both host SoCs: a750/8gen3 support is upstream
# mesa, A8xx/8 Elite comes from the gen8 patch stack.
#
# Bumping to a newer driver: rebase this branch onto upstream Banners-Turnip A8xx
# (mesa_hash.txt moves with it), verify the DroidVM patches still apply (the reject
# gate in build_turnip.sh fails the build if not), then update BANNERS_PIN in the meta
# repo's 5_prepare_turnip.sh.
cd "$(dirname "$0")"

export BUILD_VERSION="${BUILD_VERSION:-droidvm}"
export BUILD_SUFFIX="${BUILD_SUFFIX:-DroidVM}"
export EXTRA_PATCH="patches/a8xx_gen8.patch:patches/droidvm_a750_rb_ccu.patch:patches/droidvm_kgsl.patch:patches/droidvm_kgsl_priority.patch"
export EXTRA_SCRIPT="patches/a8xx_shared_mem.py"
export META_NAME="${META_NAME:-DroidVM Turnip}"
export META_DESC="${META_DESC:-DroidVM host turnip for gfxstream/venus: upstream mesa pinned via mesa_hash.txt + A8xx gen8 stack + DroidVM a750 RB CCU and kgsl fixes. KGSL build.}"

exec bash build_turnip.sh
