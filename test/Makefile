# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog

SRC_DIR := $(PWD)/../src
PROJECT_SOURCES := tt_um_synth.v

# Fallback defaults for CI environment
PDK ?= ihp-sg13g2
PDK_VERSION ?= cb7daaa8901016cf7c5d272dfa322c41f024931f
PDK_ROOT ?= $(HOME)/pdk

ifneq ($(GATES),yes)

# RTL simulation
SIM_BUILD := sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate-level simulation
SIM_BUILD := sim_build/gl
COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DUSE_POWER_PINS
COMPILE_ARGS += -DSIM
COMPILE_ARGS += -DUNIT_DELAY=\#1

# IHP SG13G2 standard cell / IO models expected from CI environment
PRIMITIVES_V := $(PDK_ROOT)/sg13g2/libs.ref/sg13g2_io_sc/verilog/primitives.v
CELLS_V      := $(PDK_ROOT)/sg13g2/libs.ref/sg13g2_io_sc/verilog/sg13g2_io_sc.v

VERILOG_SOURCES += $(PRIMITIVES_V)
VERILOG_SOURCES += $(CELLS_V)

# This gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

# Do not try to install the PDK here; the Tiny Tapeout action should provide it.
ifeq ($(wildcard $(PRIMITIVES_V)),)
$(error Missing PDK primitives: $(PRIMITIVES_V). Expected Tiny Tapeout GL test environment to provide the IHP SG13G2 PDK under $(PDK_ROOT))
endif

ifeq ($(wildcard $(CELLS_V)),)
$(error Missing PDK cells: $(CELLS_V). Expected Tiny Tapeout GL test environment to provide the IHP SG13G2 PDK under $(PDK_ROOT))
endif

ifeq ($(wildcard $(PWD)/gate_level_netlist.v)),)
$(error Missing gate-level netlist: $(PWD)/gate_level_netlist.v. Expected GL test action to copy it before simulation)
endif

endif

# Allow sharing configuration between design and testbench via `include`
COMPILE_ARGS += -I$(SRC_DIR)
COMPILE_ARGS += -DCOCOTB_SIM

# Include the testbench sources
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
