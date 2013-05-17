all: orc

%.o: %.scm
	bigloo -c $@ $^ -fidentifier-syntax bigloo

orc: misc.o orc.o
	bigloo -o $@ $^

clean:
	rm -rf orc *.o
