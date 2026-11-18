# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

# FreeBSD bmake Makefile (full bench_driver + switch dispatcher)
#
# Usage:
#   make            # builds with N=128 by default
#   make N=64       # build 64 DSOs
#   make clean
#
# First-time generation (or when changing N):
#   make gen        # generates gen/comp*.c/.h, gen/comp_dispatch.{c,h}

CC?=		cc
CFLAGS?=	-O2 -pipe -fPIC
CFLAGS+=	-std=c11 -Wall -Wextra
BUILD=		build
LIBDIR=		${BUILD}/lib
GEN=		gen
TOOLS=		tools
N?=		128

COMP_IDS!=	jot -w %03d ${N} 1
LIBS=		${COMP_IDS:S,^,${LIBDIR}/libcomp,:S,$,.so,}
BENCH_LDLIBS=	${COMP_IDS:S,^,-lcomp,}

all: gen libs ${BUILD}/bench_driver

gen: ${TOOLS}/gen_comps.py
	@mkdir -p ${GEN}
	@${TOOLS}/gen_comps.py --n ${N} --out ${GEN}

${BUILD}:
	mkdir -p ${BUILD}

${LIBDIR}: ${BUILD}
	mkdir -p ${LIBDIR}

libs: ${LIBDIR} ${LIBS}

.for id in ${COMP_IDS}
${LIBDIR}/libcomp${id}.so: ${LIBDIR} ${GEN}/comp${id}.c ${GEN}/comp${id}.h
	${CC} ${CFLAGS} -shared -o ${LIBDIR}/libcomp${id}.so ${GEN}/comp${id}.c
.endfor

${BUILD}/comp_dispatch.o: ${BUILD} ${GEN}/comp_dispatch.c ${GEN}/comp_dispatch.h
	${CC} -O2 -I. -c -o ${BUILD}/comp_dispatch.o ${GEN}/comp_dispatch.c

${BUILD}/bench_driver: ${BUILD} bench_driver.c common.h ${GEN}/comp_dispatch.h ${BUILD}/comp_dispatch.o libs
	${CC} -O2 -I. -o ${BUILD}/bench_driver bench_driver.c ${BUILD}/comp_dispatch.o \
	    -L${LIBDIR} ${BENCH_LDLIBS} -lpthread \
	    -Wl,-rpath,'$$ORIGIN/lib'

clean:
	rm -rf ${BUILD} ${GEN}
