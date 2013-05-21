all: total

%.o: %.scm
	bigloo -c $@ $^ -fidentifier-syntax bigloo

orc: misc.o orc.o
	bigloo -o $@ $^

main: print-x.o types.o ast.o eval.o pipe.o environment.o variable.o main.o
	bigloo -o $@ $^

total: total.scm
	bigloo total.scm -o total -fidentifier-syntax bigloo

clean:
	rm -rf main orc *.o total
