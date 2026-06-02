# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = tt_um_synth.v

# Fallback defaults for Volare if environment variables aren't set by CI
PDK ?= ihp-sg13g2
PDK_VERSION ?= cb7daaa8901016cf7c5d272dfa322c41f024931f
PDK_ROOT ?= /home/runner/pdk

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1

# Define absolute paths to the cell libraries
PRIMITIVES_V = $(PDK_ROOT)/sg13g2/libs.ref/sg13g2_io_sc/verilog/primitives.v
CELLS_V      = $(PDK_ROOT)/sg13g2/libs.ref/sg13g2_io_sc/verilog/sg13g2_io_sc.v

VERILOG_SOURCES += $(PRIMITIVES_V)
VERILOG_SOURCES += $(CELLS_V)
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

# --- BOOTSTRAP TRICK ---
# Force Volare to fetch the PDK files before cocotb starts compilation.
# We tap into cocotb's internal initialization hook to trigger this execution.
COCOTB_BOOTSTRAP_HACK := $(shell \
	if [ ! -f $(PRIMITIVES_V) ]; then \
		echo "PDK primitives missing. Bootstrapping Volare..." >&2; \
		python3 -m pip install --user --upgrade volare >/dev/null 2>&1; \
		python3 -m volare download --pdk $(PDK) --pdk-root $(PDK_ROOT) $(PDK_VERSION) >&2; \
	fi \
)

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)
COMPILE_ARGS 		+= -DCOCOTB_SIM

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
