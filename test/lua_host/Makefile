# Host-side CrossLua VM tests (gcc/g++ + ASAN/UBSAN). Incremental: `make -f test/lua_host/Makefile -j` rebuilds only
# what changed (a mutation run touches ONE src/lua/*.cpp: ~2 s instead of recompiling the 110 s test file). ccache is
# used when installed. test/lua_host/run.sh is the normal entry point.
OUT   ?= $(or $(TMPDIR),/tmp)/crosslua-host
MBED  ?= $(HOME)/.platformio/packages/framework-espidf/components/mbedtls/mbedtls
CCACHE := $(shell command -v ccache 2>/dev/null)
CC    := $(CCACHE) gcc
CXX   := $(CCACHE) g++

CFLAGS    = -O1 -g -DLUA_USE_C89 -Ilib/lua -w
MBEDFLAGS = -O1 -g -w -I$(MBED)/include -I$(MBED)/library -Itest/lua_host -DMBEDTLS_CONFIG_FILE='"mbedtls_host_config.h"'
# -g1 -fno-var-tracking: the 2400-line main() in test_vm.cpp blows GCC's variable-tracking limit and gets compiled twice
CXXFLAGS  = -std=c++20 -O1 -g1 -fno-var-tracking -Wall -Wextra -Ilib/lua -I$(MBED)/include -Itest/lua_host \
            -DMBEDTLS_CONFIG_FILE='"mbedtls_host_config.h"' -I. -Ilib -Ilib/InflateReader -Ilib/uzlib/src \
            -fsanitize=address,undefined -MMD -MP

CXX_SRC  := test/lua_host/test_vm.cpp $(addprefix src/lua/,LuaVm.cpp LuaApi.cpp LuaFs.cpp LuaJson.cpp LuaNet.cpp LuaZip.cpp LuaCrypto.cpp LuaSock.cpp LuaAudio.cpp LuaMic.cpp) lib/InflateReader/InflateReader.cpp
C_SRC    := $(wildcard lib/lua/*.c) lib/uzlib/src/tinflate.c
MBED_SRC := $(addprefix $(MBED)/library/,sha1.c sha256.c md.c aes.c platform_util.c constant_time.c)

CXX_OBJ  := $(patsubst %.cpp,$(OUT)/obj/%.o,$(CXX_SRC))
C_OBJ    := $(patsubst %.c,$(OUT)/obj/%.o,$(C_SRC))
MBED_OBJ := $(patsubst $(MBED)/%.c,$(OUT)/obj/mbedtls/%.o,$(MBED_SRC))

$(OUT)/test_vm: $(CXX_OBJ) $(C_OBJ) $(MBED_OBJ)
	$(CXX) $^ -fsanitize=address,undefined -o $@

$(OUT)/obj/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/obj/lib/uzlib/src/tinflate.o: lib/uzlib/src/tinflate.c
	@mkdir -p $(dir $@)
	$(CC) -O1 -g -Ilib/uzlib/src -w -c $< -o $@

$(OUT)/obj/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(OUT)/obj/mbedtls/%.o: $(MBED)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(MBEDFLAGS) -c $< -o $@

-include $(CXX_OBJ:.o=.d)
