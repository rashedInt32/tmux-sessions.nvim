.PHONY: test lint fmt

test:
	nvim --headless --clean -l tests/run.lua $(FILTER)

lint:
	stylua --check .
	luacheck lua plugin tests

fmt:
	stylua .
