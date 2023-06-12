MODULE_big = pg_failover_slots
OBJS = pg_failover_slots.o

PG_CPPFLAGS += -I $(libpq_srcdir)
SHLIB_LINK += $(libpq)

TAP_TESTS = 1

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

export PGCTLTIMEOUT = 180
