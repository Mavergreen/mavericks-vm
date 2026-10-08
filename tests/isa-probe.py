# isa-probe.py <name>: run one instruction, so a guest proves what its CPU
# lets it run. Exit 0 when it ran; killed by SIGILL (sh says 132) when the
# CPU, or the OS, does not provide it; exit 2 for a name it does not know.
#
# spec: packer-plugin-macosx docs/decisions/0009 -- the instruction-set
#       levels. It executes rather than reading sysctl: machdep.cpu says what
#       CPUID advertises, but a ymm instruction runs only when 10.9 has turned
#       on XSAVE and the AVX state, so only running one proves the level.
# platform: the guest has only Python 2.7.5 (stock 10.9), so this is 2 and 3.
#
# Each is one instruction then ret, encoded by GNU as and checked with
# objdump -d -M intel (2026-10-08).
import ctypes
import mmap
import sys

CODE = {
    "avx": b"\xc5\xfc\x57\xc0",  # vxorps ymm0,ymm0,ymm0
    "avx2": b"\xc5\xfd\xef\xc0",  # vpxor ymm0,ymm0,ymm0
    "fma": b"\xc4\xe2\x7d\xb8\xc0",  # vfmadd231ps ymm0,ymm0,ymm0
    "bmi1": b"\xc4\xe2\x78\xf2\xc0",  # andn eax,eax,eax
    "bmi2": b"\xc4\xe2\x78\xf5\xc0",  # bzhi eax,eax,eax
}
RET = b"\xc3"

if len(sys.argv) != 2 or sys.argv[1] not in CODE:
    sys.stderr.write("usage: isa-probe.py %s\n" % "|".join(sorted(CODE)))
    sys.exit(2)

page = mmap.mmap(-1, mmap.PAGESIZE, prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)
page.write(CODE[sys.argv[1]] + RET)
ctypes.CFUNCTYPE(None)(ctypes.addressof(ctypes.c_char.from_buffer(page)))()
sys.exit(0)
