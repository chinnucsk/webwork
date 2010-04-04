all:
	./rebar compile

clean:
	rm -rf tests_ebin docs
	./rebar clean

test: all
	@mkdir -p tests_ebin
	@cd tests;erl -make
	@erl -noshell -boot start_sasl -pa ebin -pa tests_ebin -s luke -eval 'test_suite:test().' -s init stop
	@rm -f ebin/test_* ebin/*_tests.erl

#docs: all
#	@mkdir -p docs
#	@./build_docs.sh