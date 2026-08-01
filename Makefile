.PHONY: app build run

app: run

build:
	./script/build_and_run.sh build

run:
	./script/build_and_run.sh
