MODULE_big = pg_failover_slots
OBJS = pg_failover_slots.o

PG_CPPFLAGS += -I $(libpq_srcdir)
SHLIB_LINK += $(libpq)

TAP_TESTS = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_failover_slots
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

export PGCTLTIMEOUT = 180
