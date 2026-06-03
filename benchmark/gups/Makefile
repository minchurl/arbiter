CC = gcc
CFLAGS = -g -Wall -O3
#CFLAGS = -g3 -Wall -O0
#INCLUDES = -I../linux-5.15.95/usr/include
LIBS = -lm -lpthread

all: gups-hotset-move gups gups-sparse gups-store

gups-sparse: gups-sparse.o timer.o
	$(CC) $(CFLAGS) $(INCLUDES) -o gups-sparse gups-sparse.o zipf.o timer.o $(LIBS)

gups-store: gups-store.o timer.o
	$(CC) $(CFLAGS) $(INCLUDES) -o gups-store gups-store.o zipf.o timer.o $(LIBS)

gups: gups.o timer.o
	$(CC) $(CFLAGS) $(INCLUDES) -o gups gups.o zipf.o timer.o $(LIBS)

gups-hotset-move: gups-hotset-move.o timer.o
	$(CC) $(CFLAGS) $(INCLUDES) -o gups-hotset-move gups-hotset-move.o zipf.o timer.o $(LIBS)

gups-optimal.o: gups-optimal.c zipf.c gups.h
	$(CC) $(CFLAGS) $(INCLUDES) -c gups-optimal.c zipf.c

gups-sparse.o: gups-sparse.c zipf.c gups.h
	$(CC) $(CFLAGS) $(INCLUDES) -c gups-sparse.c zipf.c

gups.o: gups.c zipf.c gups.h
	$(CC) $(CFLAGS) $(INCLUDES) -c gups.c zipf.c

gups-hotset-move.o: gups-hotset-move.c zipf.c gups.h
	$(CC) $(CFLAGS) $(INCLUDES) -c gups-hotset-move.c zipf.c

timer.o: timer.c timer.h
	$(CC) $(CFLAGS) $(INCLUDES) -c timer.c

clean:
	rm -rf *.o gups gups-hotset-move gups-sparse gups-store
