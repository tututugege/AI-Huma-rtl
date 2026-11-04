# tb/soc/platform

Frozen copy (19 files, about 300 KB) of the platform models of the original tututugege/simulator (commit 2f31e8d) that the closed-loop
test bench uses: `SimDDR` (DDR timing and data), `PhysMemory`, `PeripheralModel` (UART / timer / INTC registers) and the headers they include
(`config.h`, `mmio_address_map.h`, IO / type headers). They are the memory system **around** the core, not the reference CPU.
The original simulator is no longer maintained or required: this directory is the only part of it that the RTL test bench needs.
Layout mirrors the original source tree so that the unchanged relative includes keep working.
