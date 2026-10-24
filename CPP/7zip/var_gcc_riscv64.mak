PLATFORM = riscv64
O = b/g_$(PLATFORM)
USE_ASM =
# IS_X64 =
# IS_X86 =
# IS_ARM64 =
MY_ARCH ?= #native or -march=riscv64
CROSS_COMPILE ?=
CC  = $(CROSS_COMPILE)gcc
CXX = $(CROSS_COMPILE)g++
